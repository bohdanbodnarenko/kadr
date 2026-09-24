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

    /// Where Kadr's own recording controls are, so pressing Stop is not recorded as
    /// something the user did *in* the recording (docs/09 U3.2).
    var chromeOnScreen: @MainActor () -> [CGRect] {
        get { telemetry.chromeOnScreen }
        set { telemetry.chromeOnScreen = newValue }
    }

    /// How long the pointer has been on those controls, for the stop trim (docs/03 §1.8).
    var travelToControls: TimeInterval? {
        telemetry.travelToControls
    }

    /// When the user last clicked or typed, so the trim does not cut into the result of it.
    var lastInputTime: TimeInterval? {
        telemetry.lastInputTime
    }

    private let camera: CameraFileRecorder
    private var session: RecordingSession?
    /// When the session began, on the same clock the camera reports its first frame on.
    ///
    /// `systemUptime` rather than `Date`: the camera's delegate reports uptime, and the two
    /// have to be subtractable. A wall clock would also move under a time-zone change or an
    /// NTP correction mid-recording, which a duration must not.
    private var startedAtUptime: TimeInterval?

    init(camera: CameraFileRecorder = CameraFileRecorder()) {
        self.camera = camera
    }

    /// The session being captured, if one is.
    var current: RecordingSession? {
        session
    }

    /// Starts capturing beside a recording.
    ///
    /// - Parameter pointConverter: maps a screen point into the recorded frame's pixels,
    ///   which is the same conversion the live click overlay uses. A `nil` return means
    ///   the point is outside the recorded area and is simply not recorded.
    /// - Parameter pointPixelScale: the recorded display's pixels per point (docs/11 S0.5).
    ///   Written into the manifest so the export can draw the cursor at the size it was on
    ///   screen — `NSCursor` measures itself in points and the footage is in pixels.
    func start(
        recordsCamera: Bool,
        cameraDeviceID: String? = nil,
        pointConverter: @escaping @Sendable (ScreenPoint) -> PixelPoint?,
        pointPixelScale: CGFloat,
        topInset: CGFloat = 0
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
        self.pointPixelScale = pointPixelScale
        self.topInset = topInset
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        firstFrameUptime = nil
        telemetry.start(pointConverter: pointConverter, journalURL: session.inputJournalURL)
        if recordsCamera {
            camera.start(writingTo: session.cameraURL, deviceID: cameraDeviceID)
        }
        logger.info("Studio session started: \(session.directory.lastPathComponent, privacy: .public)")
    }

    /// Pairs the in-progress segment folder with this session (docs/16 REC-8).
    func linkSegments(_ directory: URL?, options: RecordingOptions) {
        guard let session, let directory else { return }
        let link = directory.appendingPathComponent("session.link")
        try? session.directory.path.write(to: link, atomically: true, encoding: .utf8)
        let reverse = session.directory.appendingPathComponent("segments.link")
        try? directory.path.write(to: reverse, atomically: true, encoding: .utf8)
        writeProvisionalManifest(options: options)
    }

    func writeProvisionalManifest(options: RecordingOptions) {
        guard let session else { return }
        try? SessionDocument(session: session).write(CaptureManifest(
            pixelSize: .zero,
            scale: pointPixelScale,
            frameRate: options.frameRate.rawValue,
            duration: 0,
            hasBakedCursor: options.showsCursor,
            hasCamera: FileManager.default.fileExists(atPath: session.cameraURL.path)
        ))
    }

    /// Advances the telemetry clock past paused time.
    ///
    /// A pause is time the user chose not to record, so it must not appear in the sidecar
    /// either: a pointer track that keeps running through a pause puts the cursor somewhere
    /// the footage never showed it.
    func advance(to elapsed: TimeInterval) {
        // The first tick is the recording's real zero (docs/11 S0.5).
        //
        // `startedAtUptime` is stamped when the *session* is created, which is before
        // `engine.start` and so before ScreenCaptureKit has spent its 200–500 ms getting a
        // stream up. Measuring the camera's arrival from there over-counts by exactly that
        // setup, which is how R0.5 replaced a +0.3–1.5 s lip-sync error with a −0.2–0.5 s
        // one. This is the moment the first frame was actually composited, which is the
        // instant camera time and screen time are supposed to share.
        if firstFrameUptime == nil, session != nil {
            firstFrameUptime = ProcessInfo.processInfo.systemUptime
        }
        telemetry.advance(to: elapsed)
    }

    /// Stops writing the camera file for a pause, without tearing the live preview down.
    func pauseCamera() {
        camera.pause()
    }

    func resumeCamera() {
        camera.resume()
    }

    func pauseTelemetry() {
        telemetry.pause()
    }

    func resumeTelemetry() {
        telemetry.resume()
    }

    // MARK: - Where the window is

    /// Pixels per point on the display being recorded.
    @ObservationIgnored private var pointPixelScale: CGFloat = 2

    /// The notch strip at the top of that display, in recorded pixels.
    @ObservationIgnored private var topInset: CGFloat = 0

    /// Uptime at the recording's first composited frame — the zero everything else is
    /// measured from (docs/11 S0.5).
    @ObservationIgnored private var firstFrameUptime: TimeInterval?

    /// Finishes the session around a completed recording, and returns it.
    ///
    /// Returns nil when there is nothing worth keeping — no session was started, or the
    /// footage could not be attached, in which case the empty package is removed rather
    /// than left for the sweep to find.
    func finish(with result: RecordingResult) async -> RecordingSession? {
        guard let session else { return nil }
        self.session = nil
        let captured = telemetry.stop()
        let cameraOutcome = await camera.finish()

        guard await attach(result.fileURL, to: session) else {
            try? session.delete()
            return nil
        }

        let document = SessionDocument(session: session)
        do {
            try document.write(captured)
            try? FileManager.default.removeItem(at: session.inputJournalURL)
            try document.write(CaptureManifest(
                pixelSize: CGSize(width: result.pixelSize.width, height: result.pixelSize.height),
                // The real thing, not a placeholder. It was hard-coded to 1 and read by
                // nothing, so every Retina export drew a half-size cursor (docs/11 S0.5).
                scale: pointPixelScale,
                frameRate: result.options.frameRate.rawValue,
                duration: result.duration,
                // Recorded rather than inferred later: whether the studio should draw a
                // cursor depends on whether one is already in the picture, and by the time
                // anybody opens the editor there is no way left to tell.
                hasBakedCursor: result.options.showsCursor,
                hasCamera: FileManager.default.fileExists(atPath: session.cameraURL.path),
                cameraStartOffset: cameraOffset(firstFrameAt: cameraOutcome.startedAt),
                topInset: topInset
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
    /// Measured from the first composited frame, which is where the footage actually
    /// begins (docs/11 S0.5).
    ///
    /// It used to be measured from the session's creation, which happens before
    /// `engine.start` and therefore before ScreenCaptureKit has spent its 200–500 ms
    /// bringing a stream up — so the answer was too large by exactly that setup, and the
    /// bubble ran that much behind the picture. The session start is kept as a fallback for
    /// the case where no frame was ever composited, where it is the only answer available
    /// and the recording has no footage to be out of sync with anyway.
    private func cameraOffset(firstFrameAt uptime: TimeInterval?) -> TimeInterval {
        guard let uptime, let zero = firstFrameUptime ?? startedAtUptime else { return 0 }
        return max(uptime - zero, 0)
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
    ///
    /// The copy runs off the main actor: a multi-gigabyte copy there froze the whole agent —
    /// menu bar, hotkeys, the card — right after Stop (docs/17 T-REC-10).
    private func attach(_ footage: URL, to session: RecordingSession) async -> Bool {
        let manager = FileManager.default
        try? manager.removeItem(at: session.screenURL)
        do {
            try manager.linkItem(at: footage, to: session.screenURL)
            return true
        } catch {
            logger.info("The recording is on another volume; copying it into the studio session")
        }
        let destination = session.screenURL
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: footage, to: destination)
            }.value
            // A copy is not a hard link: referenceCount is 1 even though the original
            // still exists on another volume, and treating it as the only copy would
            // keep every external-disk recording in Application Support forever
            // (docs/10 R3.5).
            session.markFootageAsCopy()
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
    nonisolated static func root() -> URL? {
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
    nonisolated static func store() -> RecordingSessionStore? {
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
    nonisolated static func unfinishedSessions() -> [RecordingSession] {
        store()?.sessionsNeedingRecovery() ?? []
    }

    /// Nonisolated because it lists and stats every session folder: the agent calls it
    /// from a detached task, never on the main thread (`UnfinishedRecordingsCounter`).
    nonisolated static func unfinishedCount() -> Int {
        unfinishedSessions().count
    }

    // MARK: - Seams

    /// Starts a session in a given folder, without a telemetry tap or a camera.
    ///
    /// The tap needs an accessibility grant and the camera needs a device, neither of which
    /// a test has. What a test can check is everything after: that the footage is attached,
    /// that the manifest remembers what cannot be re-derived, and that a failure leaves
    /// nothing behind.
    func startForTesting(
        in root: URL,
        pointPixelScale: CGFloat = 2,
        topInset: CGFloat = 0
    ) -> RecordingSession? {
        guard session == nil else { return nil }
        let session = RecordingSession.create(in: root, named: Self.name())
        guard (try? session.create()) != nil else { return nil }
        self.session = session
        self.pointPixelScale = pointPixelScale
        self.topInset = topInset
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        firstFrameUptime = nil
        return session
    }

    func attachForTesting(_ footage: URL, to session: RecordingSession) async -> Bool {
        await attach(footage, to: session)
    }

    /// A name that sorts by when it was recorded and collides with nothing.
    private static func name() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))"
    }
}
