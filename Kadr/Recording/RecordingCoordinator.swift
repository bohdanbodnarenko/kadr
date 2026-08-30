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
import StudioSession

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
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let overlay: SelectionOverlayController
    @ObservationIgnored private let hygiene: DesktopHygieneController?
    @ObservationIgnored private let focus = FocusMode()
    /// Click halos, keystrokes and the webcam. Started with the recording and stopped
    /// with it — none of its monitors exist while Kadr is idle (docs/03 §1.8).
    @ObservationIgnored private let overlaySource = RecordingOverlaySource()
    /// The sidecar that makes a recording editable in the studio afterwards (docs/09 U3.1).
    @ObservationIgnored private let studio = StudioSessionRecorder()
    /// The script somebody reads from while recording (docs/08).
    @ObservationIgnored private lazy var teleprompter = TeleprompterController(settings: settings)
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
    @ObservationIgnored var tickTask: Task<Void, Never>?
    @ObservationIgnored var startedAt: Date?
    @ObservationIgnored var pausedDuration: TimeInterval = 0
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

    /// Whether a recording exists — including one still starting up.
    ///
    /// Everything that guards against a second recording asks this, so it has to be true
    /// for the whole life of one, not just the part after the stream is running.
    var isRecording: Bool {
        state.isActive && state != .finishing
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
                await CaptureExclusionPush.into(captureEngine)
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
        // Claimed synchronously, before the first await (docs/10 R0.3).
        //
        // Setting up a capture is a few hundred milliseconds of asking ScreenCaptureKit
        // for permission, content and a stream. `state` used to become `.recording` only
        // after all of it, so throughout that window the app reported itself idle, the
        // menu items stayed enabled, and a second press started a second recording — whose
        // failure path then ran `studio.cancel()`, deleting the *first* recording's session
        // directory, and put the desktop icons back while the first was still filming.
        guard !isRecording else { return }
        state = .starting

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
                teleprompter.start()
                await CaptureExclusionPush.into(engine)
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
                teleprompter.stop()
                hygiene?.endRecording()
                state = .idle
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
        observeClock()
        observeGeometry()
    }

    /// Feeds the recording's clock to the sidecar (docs/10 R0.1).
    ///
    /// Installed for every studio capture and nothing else. Without it the telemetry
    /// recorder's clock never moves: every click and chord is stamped zero, and the
    /// sample-rate gate — which asks whether enough time has passed since the last sample —
    /// compares zero against zero and refuses every pointer sample after the first.
    private func observeClock() {
        Task { [weak self] in
            await self?.engine.setClockObserver { [weak self] time in
                Task { @MainActor [weak self] in self?.studio.advance(to: time) }
            }
        }
    }

    private func stopClockObserver() {
        Task { [weak self] in await self?.engine.setClockObserver(nil) }
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
        stopClockObserver()
    }

    /// Tears every overlay monitor down. Called on stop, cancel and a failed start.
    private func stopOverlays() {
        overlaySource.stop()
        overlaySource.resetClock()
        Task { await engine.setOverlayProvider(nil) }
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
            do {
                try await engine.pause()
            } catch {
                logger.error("Could not pause: \(error.localizedDescription, privacy: .public)")
                return
            }
            // The script holds where it is: a prompter that keeps scrolling through a
            // pause is one the reader has to scroll back on when they resume.
            teleprompter.pause()
            state = .paused
            pausedAt = Date()
            stopTicking()
        }
    }

    func resume() {
        guard state == .paused else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.resume()
            } catch {
                logger.error("Could not resume: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let pausedAt {
                // Paused time is time the user chose not to record, so the clock skips it
                // exactly as the file does.
                pausedDuration += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            state = .recording
            teleprompter.resume()
            // The sidecar's clock needs no nudge here. It comes from the engine, which
            // counts composited frames and so has already left the pause out — deriving a
            // second answer from the wall clock would only give the two something to
            // disagree about.
            startTicking()
        }
    }

    /// Stops and finalises. `completion` is how `kadr stop-recording` learns the path.
    func stop(reportingTo completion: ((CaptureOutcome) -> Void)? = nil) {
        guard isRecording else {
            completion?(.failed("Nothing is recording."))
            return
        }
        // Stopped before the stream came up. There is no footage to finalise, so this is a
        // cancellation — finalising would ask the engine to stop something it never started
        // and report "recording failed to finish" for a recording that never began.
        guard state != .starting else {
            cancel()
            completion?(.cancelled)
            return
        }
        automationCompletion = completion
        state = .finishing
        stopTicking()
        focus.disable()
        stopOverlays()
        stopGeometryObserver()
        teleprompter.stop()
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
        state = .idle
        stopTicking()
        focus.disable()
        stopOverlays()
        hygiene?.endRecording()
        studio.cancel()
        stopGeometryObserver()
        teleprompter.stop()
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

    // MARK: - The clock the menu bar reads

    /// Ticks the elapsed time while recording.
    ///
    /// Kept beside the state rather than in the plumbing extension because it writes
    /// `elapsed`, whose setter is private to this file — and an extension that cannot
    /// reach the thing it exists to update is worse than no extension.
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
