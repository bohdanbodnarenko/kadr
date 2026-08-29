import AppKit
import Foundation
import os
import RecordingCore
import Shared
import StudioCore

/// Captures the sidecar that makes a recording editable in the studio (docs/09 U3.1).
///
/// The recording itself is unchanged: the engine writes the same file to the same place
/// whether this is running or not. What this adds is everything that cannot be recovered
/// afterwards — where the pointer went, what was clicked, which chords were pressed, what
/// the cursor looked like — written beside the footage in a `.kadrrec` package.
///
/// That asymmetry is the whole argument for capturing it by default. The footage can be
/// re-edited forever; the telemetry exists only while the recording is happening, and a
/// recording made without it can never be given smooth zooms or reconstructed clicks.
@MainActor
final class StudioSessionRecorder {
    private let logger = KadrLog.logger(.recording)
    private let telemetry = PointerTelemetryRecorder()
    private let camera = CameraFileRecorder()
    private var session: RecordingSession?
    private var startedAt: Date?

    /// The session being captured, if one is.
    var current: RecordingSession? {
        session
    }

    /// Starts capturing beside a recording.
    ///
    /// - Parameter pointConverter: maps a screen point into the recorded frame's pixels,
    ///   which is the same conversion the live click overlay uses. A `nil` return means
    ///   the point is outside the recorded area and is simply not recorded.
    func start(
        recordsCamera: Bool,
        pointConverter: @escaping @Sendable (CGPoint) -> CGPoint?
    ) {
        guard session == nil else { return }
        guard let root = Self.root() else {
            logger.error("Could not find Application Support; recording without a studio session")
            return
        }

        let session = RecordingSession.create(in: root, named: Self.name())
        do {
            try session.create()
        } catch {
            // The recording goes ahead regardless. A studio session is an enhancement, and
            // failing to make one is not a reason to refuse to record.
            logger.error("Could not create a studio session: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.session = session
        startedAt = Date()
        telemetry.start(pointConverter: pointConverter)
        if recordsCamera {
            camera.start(writingTo: session.cameraURL)
        }
        logger.info("Studio session started: \(session.directory.lastPathComponent, privacy: .public)")
    }

    /// Advances the telemetry clock past paused time.
    ///
    /// A pause is time the user chose not to record, so it must not appear in the sidecar
    /// either: a pointer track that keeps running through a pause puts the cursor somewhere
    /// the footage never showed it.
    func advance(to elapsed: TimeInterval) {
        telemetry.advance(to: elapsed)
    }

    /// Finishes the session around a completed recording, and returns it.
    ///
    /// Returns nil when there is nothing worth keeping — no session was started, or the
    /// footage could not be attached, in which case the empty package is removed rather
    /// than left for the sweep to find.
    func finish(with result: RecordingResult) async -> RecordingSession? {
        guard let session else { return nil }
        self.session = nil
        let captured = telemetry.stop()
        await camera.finish()

        guard attach(result.fileURL, to: session) else {
            try? session.delete()
            return nil
        }

        let document = SessionDocument(session: session)
        do {
            try document.write(captured)
            try document.write(CaptureManifest(
                pixelSize: CGSize(width: result.pixelSize.width, height: result.pixelSize.height),
                scale: 1,
                frameRate: result.options.frameRate.rawValue,
                duration: result.duration,
                // Recorded rather than inferred later: whether the studio should draw a
                // cursor depends on whether one is already in the picture, and by the time
                // anybody opens the editor there is no way left to tell.
                hasBakedCursor: result.options.showsCursor,
                hasCamera: FileManager.default.fileExists(atPath: session.cameraURL.path)
            ))
        } catch {
            logger.error("Could not write the studio session: \(error.localizedDescription, privacy: .public)")
            try? session.delete()
            return nil
        }

        logger.info("Studio session ready: \(session.directory.lastPathComponent, privacy: .public)")
        return session
    }

    func cancel() {
        guard let session else { return }
        self.session = nil
        _ = telemetry.stop()
        camera.cancel()
        try? session.delete()
    }

    // MARK: - Attaching the footage

    /// Puts the recording into the session without writing a second copy of it.
    ///
    /// A hard link, so the bytes exist once and both paths are real files: deleting the
    /// user's recording does not empty the session, and sweeping the session does not take
    /// the recording. Copying instead would double the disk cost of every recording, which
    /// for a screen recorder is the one cost that is never acceptable.
    ///
    /// A link cannot cross volumes, so a save folder on an external disk falls back to a
    /// copy — chosen deliberately over abandoning the session, because the user turned this
    /// on and a slow success beats a silent nothing. It is logged either way.
    private func attach(_ footage: URL, to session: RecordingSession) -> Bool {
        let manager = FileManager.default
        try? manager.removeItem(at: session.screenURL)
        do {
            try manager.linkItem(at: footage, to: session.screenURL)
            return true
        } catch {
            logger.info("The recording is on another volume; copying it into the studio session")
        }
        do {
            try manager.copyItem(at: footage, to: session.screenURL)
            return true
        } catch {
            logger.error("Could not attach the recording: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Where sessions live

    /// The sessions folder, in Application Support.
    ///
    /// Not the temporary directory: macOS purges that on its own schedule, and a session
    /// holding the only copy of an unfinished edit is not something to leave where the
    /// system may decide to reclaim it.
    static func root() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return RecordingSession.defaultRoot(applicationSupport: support)
    }

    // MARK: - Seams

    /// Starts a session in a given folder, without a telemetry tap or a camera.
    ///
    /// The tap needs an accessibility grant and the camera needs a device, neither of which
    /// a test has. What a test can check is everything after: that the footage is attached,
    /// that the manifest remembers what cannot be re-derived, and that a failure leaves
    /// nothing behind.
    func startForTesting(in root: URL) -> RecordingSession? {
        guard session == nil else { return nil }
        let session = RecordingSession.create(in: root, named: Self.name())
        guard (try? session.create()) != nil else { return nil }
        self.session = session
        startedAt = Date()
        return session
    }

    func attachForTesting(_ footage: URL, to session: RecordingSession) -> Bool {
        attach(footage, to: session)
    }

    /// A name that sorts by when it was recorded and collides with nothing.
    private static func name() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))"
    }
}
