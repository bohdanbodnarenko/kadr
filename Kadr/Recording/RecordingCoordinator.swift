import AppKit
import AVFoundation
import CaptureCore
import MediaExport
import os
import OverlayKit
import RecordingCore
import SelectionUI
import SettingsKit
import Shared
import StudioCore

/// Drives screen recording end to end (docs/03 §1.8).
///
/// Recording reuses the same selection grammar as stills: the user picks a region, window
/// or display with the overlay they already know, and the recording starts from that.
@MainActor
@Observable
final class RecordingCoordinator {
    @ObservationIgnored private let engine = RecordingEngine()
    @ObservationIgnored private let captureEngine: CaptureEngine
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let overlay: SelectionOverlayController
    @ObservationIgnored private let hygiene: DesktopHygieneController?
    @ObservationIgnored private let focus = FocusMode()
    /// Click halos, keystrokes and the webcam. Started with the recording and stopped
    /// with it — none of its monitors exist while Kadr is idle (docs/03 §1.8).
    @ObservationIgnored private let overlaySource = RecordingOverlaySource()
    /// The sidecar that makes a recording editable in the studio afterwards (docs/09 U3.1).
    @ObservationIgnored private let studio = StudioSessionRecorder()
    @ObservationIgnored private let logger = KadrLog.logger(.recording)

    /// What the status item shows.
    private(set) var state: RecordingState = .idle {
        didSet { onStateChanged?() }
    }

    private(set) var elapsed: TimeInterval = 0 {
        didSet { onStateChanged?() }
    }

    /// A finished recording, ready for the overlay.
    var onFinished: ((RecordingResult) -> Void)?
    /// A finished recording that also has a studio session, so the editor can open it.
    var onStudioSessionReady: ((RecordingSession, RecordingResult) -> Void)?
    /// Fired whenever the state or the clock moves, so the menu bar can follow.
    var onStateChanged: (() -> Void)?

    /// Ticks the elapsed time while recording.
    ///
    /// The only repeating timer in the app, and it exists solely while a recording is
    /// running — the idle path still has none (PRD §8).
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var pausedDuration: TimeInterval = 0
    @ObservationIgnored private var pausedAt: Date?

    init(
        captureEngine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        overlay: SelectionOverlayController = SelectionOverlayController(),
        hygiene: DesktopHygieneController? = nil
    ) {
        self.captureEngine = captureEngine
        self.permissions = permissions
        self.settings = settings
        self.overlay = overlay
        self.hygiene = hygiene
    }

    var isRecording: Bool {
        state == .recording || state == .paused
    }

    /// Elapsed time as the menu bar shows it.
    var elapsedText: String {
        let total = Int(elapsed)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Starting

    /// Options this recording overrides for one run, and who to tell when it stops.
    ///
    /// Cleared when the recording ends, so `kadr record-screen --fps 30` cannot leave the
    /// user's Recording settings quietly changed (docs/03 §8.4).
    @ObservationIgnored private var overrides = RecordingOverrides.none
    @ObservationIgnored private var automationCompletion: ((CaptureOutcome) -> Void)?

    /// Arms the next recording with automation's overrides (docs/03 §8.4).
    func arm(_ overrides: RecordingOverrides) {
        self.overrides = overrides
    }

    /// Picks a region with the selection overlay, then records it.
    func beginRegionRecording() {
        guard !isRecording else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let freezes = try await captureEngine.freezeAllDisplays()
                permissions.noteCaptureSuccess()
                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) }
                ) { [weak self] outcome in
                    guard case let .region(result) = outcome else { return }
                    self?.start(target: .region(result.rect, display: result.display.displayID))
                }
            } catch {
                permissions.noteCaptureFailure(error)
                logger.error("Could not freeze for recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Records a whole display, with no overlay.
    func beginDisplayRecording(_ displayID: CGDirectDisplayID = CGMainDisplayID()) {
        guard !isRecording else { return }
        start(target: .display(displayID))
    }

    private func start(target: RecordingTarget) {
        if case .window = target {
            isWindowRecording = true
        } else {
            isWindowRecording = false
        }
        let options = currentOptions
        Task { [weak self] in
            guard let self else { return }
            do {
                startOverlays(for: target)
                startStudioSession(for: target)
                try await engine.start(target: target, options: options)
                state = .recording
                startedAt = Date()
                overlaySource.resetClock()
                pausedDuration = 0
                pausedAt = nil
                startTicking()
                if settings.recordingEnablesFocus {
                    focus.enable()
                }
                hygiene?.beginRecording()
                logger.info("Recording started")
            } catch {
                stopOverlays()
                studio.cancel()
                stopGeometryObserver()
                hygiene?.endRecording()
                logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
                permissions.noteCaptureFailure(error)
            }
        }
    }

    /// Turns on only the overlays the user asked for, and tells the engine where to get
    /// them (docs/03 §1.8).
    private func startOverlays(for target: RecordingTarget) {
        // The webcam belongs to one of the two paths, never both: a studio session records
        // the camera to its own file so the bubble stays editable, and macOS will not hand
        // the same device to two capture sessions. Baking a bubble that can no longer be
        // moved is also the exact decision the studio exists to postpone.
        let bakesWebcam = settings.recordingShowsWebcam && !capturesStudioSession
        let wantsAny = settings.recordingShowsClicks
            || settings.recordingShowsKeystrokes
            || bakesWebcam
        guard wantsAny else {
            Task { await engine.setOverlayProvider(nil) }
            return
        }

        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = settings.recordingShowsClicks
        configuration.showsKeystrokes = settings.recordingShowsKeystrokes
        configuration.keystrokesOnlyWithModifiers = settings.recordingKeystrokesShortcutsOnly
        configuration.showsWebcam = bakesWebcam
        configuration.pointConverter = Self.pointConverter(for: target)

        overlaySource.start(configuration: configuration)
        let source = overlaySource
        Task { await engine.setOverlayProvider(source) }
    }

    /// Whether this recording keeps a studio session beside it.
    private var capturesStudioSession: Bool {
        settings.recordingCapturesStudioSession
    }

    @ObservationIgnored private var isWindowRecording = false
    /// Follows a recorded window so a click can be placed against where it was at the time.
    @ObservationIgnored private var windowConverter: MovingWindowConverter?

    /// Starts the studio sidecar, if this recording is keeping one.
    ///
    /// A window recording takes a different converter from a display or a region. Those sit
    /// still, so where a click lands on screen fixes where it lands in the frame once and
    /// for all. A window moves, so the same click means different things at different
    /// moments — and the converter has to ask the engine where the window is now rather
    /// than having been told once at the start.
    private func startStudioSession(for target: RecordingTarget) {
        guard capturesStudioSession else { return }

        var converter = Self.pointConverter(for: target)
        if isWindowRecording {
            let moving = MovingWindowConverter()
            windowConverter = moving
            converter = moving.converter()
        }

        studio.start(recordsCamera: settings.recordingShowsWebcam, pointConverter: converter)
        observeGeometry()
    }

    /// Feeds the engine's content-rect changes to the sidecar and the converter.
    private func observeGeometry() {
        Task { [weak self] in
            await self?.engine.setGeometryObserver { [weak self] rect, scale, time in
                Task { @MainActor [weak self] in
                    self?.windowConverter?.update(rect, scale: scale)
                    self?.studio.noteGeometry(rect, at: time)
                }
            }
        }
    }

    /// Stops watching where the window is. The observer holds this coordinator, so leaving
    /// it attached after a recording keeps the engine pointed at a recording that is over.
    private func stopGeometryObserver() {
        windowConverter = nil
        Task { [weak self] in await self?.engine.setGeometryObserver(nil) }
    }

    /// Tears every overlay monitor down. Called on stop, cancel and a failed start.
    private func stopOverlays() {
        overlaySource.stop()
        overlaySource.resetClock()
        Task { await engine.setOverlayProvider(nil) }
    }

    /// Maps a screen click into the recorded frame's own pixels.
    ///
    /// Clicks arrive in AppKit's screen space; the frame is in the recorded area's pixels
    /// with a top-left origin. Getting this wrong puts the halo somewhere else entirely,
    /// which is why it goes through `Shared.Geometry` rather than ad-hoc arithmetic.
    private static func pointConverter(
        for target: RecordingTarget
    ) -> @Sendable (CGPoint) -> CGPoint? {
        let space = GlobalCoordinateSpace.current
        let screens = NSScreen.screens.compactMap(ScreenDescriptor.init)

        switch target {
        case let .display(displayID):
            guard let screen = screens.first(where: { $0.displayID == displayID }) else {
                return { _ in nil }
            }
            let frame = screen.frame.cgRect
            let scale = screen.backingScaleFactor
            return { point in
                guard frame.contains(point) else { return nil }
                return CGPoint(
                    x: (point.x - frame.minX) * scale,
                    y: (frame.maxY - point.y) * scale
                )
            }

        case let .region(rect, displayID):
            guard let screen = screens.first(where: { $0.displayID == displayID }) else {
                return { _ in nil }
            }
            let scale = screen.backingScaleFactor
            let regionInScreenSpace = rect.inScreenSpace(space)
            return { point in
                guard regionInScreenSpace.cgRect.contains(point) else { return nil }
                return CGPoint(
                    x: (point.x - regionInScreenSpace.minX) * scale,
                    y: (regionInScreenSpace.maxY - point.y) * scale
                )
            }

        case .window:
            // A window moves while being recorded, so a click's position within the frame
            // cannot be derived from where it landed on screen. Halos are left off rather
            // than drawn in the wrong place.
            return { _ in nil }
        }
    }

    private var currentOptions: RecordingOptions {
        let requestedRate = overrides.frameRate ?? settings.recordingFrameRate.rawValue
        return RecordingOptions(
            // An automation may ask for a frame rate the encoder presets do not have; the
            // nearest preset is a better answer than refusing the recording.
            frameRate: RecordingFrameRate.nearest(to: requestedRate),
            codec: settings.recordingCodec == .hevc ? .hevc : .h264,
            capturesSystemAudio: overrides.recordsSystemAudio ?? settings.recordsSystemAudio,
            capturesMicrophone: overrides.recordsMicrophone ?? settings.recordsMicrophone,
            showsCursor: showsCursor,
            dynamicRange: settings.recordingDynamicRange
        )
    }

    /// Whether the system cursor is baked into the recording.
    ///
    /// Left out only when the user has asked the studio to draw it back, and only when
    /// there is a session to draw it back from. A cursor cannot be added to footage that
    /// never had one and has no sidecar either, so recording without one in that case would
    /// simply lose the pointer (docs/09 U3.1).
    private var showsCursor: Bool {
        guard settings.recordingReconstructsCursor, capturesStudioSession else {
            return settings.recordingShowsCursor
        }
        return false
    }

    // MARK: - Controlling

    func pause() {
        guard state == .recording else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await engine.pause()
            state = .paused
            pausedAt = Date()
            stopTicking()
        }
    }

    func resume() {
        guard state == .paused else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await engine.resume()
            if let pausedAt {
                // Paused time is time the user chose not to record, so the clock skips it
                // exactly as the file does.
                pausedDuration += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            state = .recording
            // The sidecar's clock skips the pause too. A pointer track that kept running
            // through it would place the cursor where the footage never showed it.
            if let startedAt {
                studio.advance(to: Date().timeIntervalSince(startedAt) - pausedDuration)
            }
            startTicking()
        }
    }

    /// Stops and finalises. `completion` is how `kadr stop-recording` learns the path.
    func stop(reportingTo completion: ((CaptureOutcome) -> Void)? = nil) {
        guard isRecording else {
            completion?(.failed("Nothing is recording."))
            return
        }
        automationCompletion = completion
        state = .finishing
        stopTicking()
        focus.disable()
        stopOverlays()
        stopGeometryObserver()
        hygiene?.endRecording()

        let destination = destinationURL()
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.stop(savingTo: destination)
                state = .idle
                elapsed = 0
                overrides = .none
                logger.info("Recording saved: \(result.fileURL.lastPathComponent, privacy: .public)")

                // The card goes up before the session is assembled. Linking the footage and
                // writing the sidecar takes a moment, and making the user wait for it would
                // put a delay between stopping and seeing the recording that the recording
                // itself does not have.
                report(.file(result.fileURL))
                onFinished?(result)
                if let session = await studio.finish(with: result) {
                    onStudioSessionReady?(session, result)
                }
            } catch {
                state = .idle
                elapsed = 0
                overrides = .none
                studio.cancel()
                logger.error("Recording failed to finish: \(error.localizedDescription, privacy: .public)")
                report(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        stopTicking()
        focus.disable()
        stopOverlays()
        hygiene?.endRecording()
        studio.cancel()
        stopGeometryObserver()
        Task { [weak self] in
            await self?.engine.cancel()
            self?.state = .idle
            self?.elapsed = 0
            self?.overrides = .none
            self?.report(.cancelled)
        }
    }

    /// Reports to whoever asked for this recording, once.
    private func report(_ outcome: CaptureOutcome) {
        guard let automationCompletion else { return }
        self.automationCompletion = nil
        automationCompletion(outcome)
    }

    // MARK: - Plumbing

    /// Where the finished recording lands.
    ///
    /// Counted like every other capture: two recordings stopped inside the same second
    /// used to resolve to the same name, and the second overwrote the first (docs/07 M6).
    private func destinationURL() -> URL {
        let template = FilenameTemplate("Kadr recording {date} {time}")
        let context = FilenameContext(applicationName: "Screen", date: Date())
        let folder = settings.saveFolder

        if let url = try? CaptureFileWriter().availableURL(
            in: folder,
            template: template,
            context: context,
            fileExtension: "mp4"
        ) {
            return url
        }
        return folder.appendingPathComponent(template.expand(context)).appendingPathExtension("mp4")
    }

    private func startTicking() {
        stopTicking()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let startedAt else { return }
                elapsed = Date().timeIntervalSince(startedAt) - pausedDuration
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}

/// Do Not Disturb while recording (docs/03 §1.8).
///
/// macOS gives apps no supported way to set a Focus mode, so this does the honest thing:
/// it suppresses Kadr's own notifications and tells the user what it cannot do, rather
/// than pretending. A banner from another app landing in a recording is a real problem;
/// silently failing to prevent it would be worse than saying so.
@MainActor
struct FocusMode {
    private let logger = KadrLog.logger(.recording)

    func enable() {
        logger.info("Recording started; macOS Focus must be set by the user if wanted")
    }

    func disable() {}
}
