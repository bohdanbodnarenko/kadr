import AppKit
import Foundation
import ImageIO
import os
import RecordingCore
import Shared
import StudioSession
import UniformTypeIdentifiers

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
    /// When the session began, on the same clock the camera reports its first frame on.
    ///
    /// `systemUptime` rather than `Date`: the camera's delegate reports uptime, and the two
    /// have to be subtractable. A wall clock would also move under a time-zone change or an
    /// NTP correction mid-recording, which a duration must not.
    private var startedAtUptime: TimeInterval?

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
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        geometry.reset()
        telemetry.start(pointConverter: pointConverter, journalURL: session.inputJournalURL)
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

    // MARK: - Where the window is

    /// Where the recorded content sits on screen right now, and how it has moved.
    ///
    /// Kept here rather than inside the telemetry recorder because it belongs to the
    /// *capture*, not to the pointer: the same answer places a click, and is written to the
    /// sidecar so the studio can anchor a zoom to a button rather than to a screen position
    /// the button has since left.
    @ObservationIgnored private var geometry = WindowGeometryTracker()

    /// Notes that the recorded content has moved.
    func noteGeometry(_ frame: CGRect, at time: TimeInterval) {
        guard session != nil else { return }
        geometry.record(frame, at: time)
    }

    /// Finishes the session around a completed recording, and returns it.
    ///
    /// Returns nil when there is nothing worth keeping — no session was started, or the
    /// footage could not be attached, in which case the empty package is removed rather
    /// than left for the sweep to find.
    func finish(with result: RecordingResult) async -> RecordingSession? {
        guard let session else { return nil }
        self.session = nil
        var captured = telemetry.stop()
        captured.windowGeometry = geometry.samples
        geometry.reset()
        let cameraOutcome = await camera.finish()

        guard attach(result.fileURL, to: session) else {
            try? session.delete()
            return nil
        }

        let document = SessionDocument(session: session)
        do {
            try document.write(captured)
            try? FileManager.default.removeItem(at: session.inputJournalURL)
            try document.write(CaptureManifest(
                pixelSize: CGSize(width: result.pixelSize.width, height: result.pixelSize.height),
                scale: 1,
                frameRate: result.options.frameRate.rawValue,
                duration: result.duration,
                // Recorded rather than inferred later: whether the studio should draw a
                // cursor depends on whether one is already in the picture, and by the time
                // anybody opens the editor there is no way left to tell.
                hasBakedCursor: result.options.showsCursor,
                hasCamera: FileManager.default.fileExists(atPath: session.cameraURL.path),
                cameraStartOffset: cameraOffset(firstFrameAt: cameraOutcome.startedAt)
            ))
        } catch {
            logger.error("Could not write the studio session: \(error.localizedDescription, privacy: .public)")
            try? session.delete()
            return nil
        }

        await writePoster(for: session)
        logger.info("Studio session ready: \(session.directory.lastPathComponent, privacy: .public)")
        return session
    }

    /// How far into the recording the camera's first frame landed (docs/10 R0.5).
    ///
    /// Measured against the session's own start rather than the engine's first frame,
    /// which are a few milliseconds apart — the session is created immediately before the
    /// stream is asked to start. That is an approximation, and it is the right one to make:
    /// the error it replaces is a third of a second on a built-in camera and well over a
    /// second on some external ones, and it was previously assumed to be zero.
    private func cameraOffset(firstFrameAt uptime: TimeInterval?) -> TimeInterval {
        guard let uptime, let startedAtUptime else { return 0 }
        return max(uptime - startedAtUptime, 0)
    }

    /// Writes a still from the recording into the session (docs/09 U3.1).
    ///
    /// So that anything showing a session — the recovery prompt, a future browser — can
    /// show what it is without decoding a movie to find out. A recovery list that has to
    /// open four recordings to draw itself is a recovery list that appears slowly at exactly
    /// the moment somebody is anxious about their work.
    ///
    /// Best-effort: a session with no poster is a session that shows a placeholder, which is
    /// not worth failing a recording over.
    private func writePoster(for session: RecordingSession) async {
        guard let image = await VideoPosterFrame.posterFrame(of: session.screenURL, maxPixelSize: 640) else {
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            session.posterURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return
        }
        // Modest quality on purpose: this is a thumbnail beside a movie, and a poster that
        // costs a megabyte would be most of what a session weighs once its footage is
        // shared with the user's own recording.
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
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

    // MARK: - Housekeeping

    /// The store over the sessions folder, if there is one to look at.
    static func store() -> RecordingSessionStore? {
        root().map(RecordingSessionStore.init(root:))
    }

    /// Tidies the sessions folder. Called once at launch, never on a timer.
    ///
    /// Two sweeps with different rules. Packages with no footage in them are litter from a
    /// recording that failed before writing a frame, and go immediately. Packages that have
    /// aged out go only when the footage is still linked from the user's own recording —
    /// a session holding the last copy *is* the recording, and is kept however old it is.
    static func sweep() {
        guard let store = store() else { return }
        store.sweepEmpty()
        store.sweepExpired()
    }

    /// The session belonging to a recording, if it still has one.
    static func session(forRecordingAt url: URL) -> RecordingSession? {
        store()?.session(forFootageAt: url)
    }

    /// Sessions a crash left mid-edit: footage, a draft, and no committed edit.
    ///
    /// A session with a committed edit was finished with at some point, so reopening it is
    /// the user's business rather than a rescue. The distinction is what keeps the recovery
    /// prompt rare enough to mean something.
    static func unfinishedSessions() -> [RecordingSession] {
        store()?.sessionsNeedingRecovery() ?? []
    }

    static func unfinishedCount() -> Int {
        unfinishedSessions().count
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
        startedAtUptime = ProcessInfo.processInfo.systemUptime
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
