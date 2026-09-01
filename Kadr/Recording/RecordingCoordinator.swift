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
    @ObservationIgnored let engine = RecordingEngine()
    @ObservationIgnored private let captureEngine: CaptureEngine
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let overlay: SelectionOverlayController
    @ObservationIgnored let hygiene: DesktopHygieneController?
    @ObservationIgnored let focus = FocusMode()
    /// Click halos, keystrokes and the webcam. Started with the recording and stopped
    /// with it — none of its monitors exist while Kadr is idle (docs/03 §1.8).
    @ObservationIgnored private let overlaySource = RecordingOverlaySource()
    /// The sidecar that makes a recording editable in the studio afterwards (docs/09 U3.1).
    @ObservationIgnored let studio = StudioSessionRecorder()
    /// The script somebody reads from while recording (docs/08).
    @ObservationIgnored lazy var teleprompter = TeleprompterController(settings: settings)
    @ObservationIgnored let logger = KadrLog.logger(.recording)
    @ObservationIgnored let recovery = PermissionRecovery()

    /// What the status item shows.
    /// Setter is target-internal rather than file-private: the pause/stop/cancel half of
    /// this state machine lives in `RecordingCoordinator+Control.swift`, and this is the app
    /// target — nothing outside it can reach the coordinator at all.
    var state: RecordingState = .idle {
        didSet { onStateChanged?() }
    }

    var elapsed: TimeInterval = 0 {
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
    @ObservationIgnored var pausedAt: Date?

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
    @ObservationIgnored var overrides = RecordingOverrides.none
    @ObservationIgnored var automationCompletion: ((CaptureOutcome) -> Void)?

    /// Arms the next recording with automation's overrides (docs/03 §8.4).
    func arm(_ overrides: RecordingOverrides) {
        self.overrides = overrides
        startedByAutomation = true
    }

    /// Whether the recording about to start was asked for by a script rather than a person.
    @ObservationIgnored var startedByAutomation = false

    /// Picks a region with the selection overlay, then records it.
    func beginRegionRecording() {
        guard !isRecording else { return }
        guard recovery.allowCapture(permissions: permissions, includePicker: false) else { return }
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
                    self?.startAfterCountdown(
                        target: .region(result.rect, display: result.display.displayID)
                    )
                }
            } catch {
                permissions.noteCaptureFailure(error)
                logger.error("Could not freeze for recording: \(error.localizedDescription, privacy: .public)")
                presentPermissionRecoveryIfNeeded(error)
            }
        }
    }

    /// Records a whole display, with no overlay.
    func beginDisplayRecording(_ displayID: CGDirectDisplayID = CGMainDisplayID()) {
        guard !isRecording else { return }
        startAfterCountdown(target: .display(displayID))
    }

    /// - Parameter alreadyClaimed: true when a countdown has already moved the state to
    ///   `.starting` on this recording's behalf. Dropping back to `.idle` first would work,
    ///   but every observer sees that — the menu-bar icon and the floating bar both react to
    ///   the state, so the bar would be torn down and rebuilt in the same breath and the
    ///   user would watch it blink between the countdown ending and the recording starting.
    func start(target: RecordingTarget, alreadyClaimed: Bool = false) {
        guard recovery.allowCapture(permissions: permissions, includePicker: false) else { return }
        // Claimed synchronously, before the first await (docs/10 R0.3).
        //
        // Setting up a capture is a few hundred milliseconds of asking ScreenCaptureKit
        // for permission, content and a stream. `state` used to become `.recording` only
        // after all of it, so throughout that window the app reported itself idle, the
        // menu items stayed enabled, and a second press started a second recording — whose
        // failure path then ran `studio.cancel()`, deleting the *first* recording's session
        // directory, and put the desktop icons back while the first was still filming.
        if !alreadyClaimed {
            guard !isRecording else { return }
            state = .starting
        }

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
                // Still ours to claim (docs/11 S0.3).
                //
                // Everything above suspends, and Stop and Cancel both run to completion
                // during those suspensions: they set `.idle`, tear the overlays down and
                // call `studio.cancel()`, which deletes the session directory. Announcing
                // `.recording` afterwards resurrected a recording the user had already
                // stopped — the menu-bar timer counted up against a session that no longer
                // existed on disk. If the state moved out from under us, the engine has
                // already been told to stand down and there is nothing here to claim.
                guard state == .starting else {
                    await engine.cancel()
                    logger.info("Recording was stopped while it was still starting")
                    return
                }
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
                // A cancellation is not a capture failure. Feeding it to the permission
                // tracker would count the user's own Escape as evidence that screen
                // recording is broken, and eventually prompt them to fix a working grant.
                guard error as? RecordingError != .cancelledDuringStart else {
                    logger.info("Recording was cancelled while it was still starting")
                    return
                }
                logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
                permissions.noteCaptureFailure(error)
                presentPermissionRecoveryIfNeeded(error)
            }
        }
    }

    /// The monthly Sequoia nag and a missing grant look the same to ScreenCaptureKit.
    /// Surface them here so a recording that never started is not a silent no-op.
    private func presentPermissionRecoveryIfNeeded(_ error: any Error) {
        guard CaptureError.mapping(error).indicatesPermissionLoss else { return }
        switch recovery.present(state: permissions.state, includePicker: false) {
        case .openSettings:
            recovery.openSystemSettings()
        case .usePicker, .dismiss:
            break
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
        // Nothing is baked into an HDR recording (docs/11 S0.5).
        //
        // HDR moves the stream to `ARGB2101010LEPacked`, and `CGBitmapContext` has no
        // representation for it — not a missing branch, an absent capability: no
        // combination of bits-per-component, alpha and byte order CoreGraphics accepts
        // describes that layout. It used to be described as 8-bit BGRA instead, which
        // *succeeded*, because both are four bytes per pixel, and then reinterpreted
        // 10-bit data as 8888 over every pixel the overlay touched. Two independent
        // switches in the same settings pane.
        //
        // Skipped rather than worked around, because the studio already draws all of this
        // at export time from the telemetry — and does it better, since an overlay that was
        // never baked can still be turned off, moved or restyled afterwards. The user loses
        // nothing but the preview-in-the-file, and gains a recording whose pixels are the
        // ones the display sent.
        guard !currentOptions.recordsHDR else {
            logger.info("HDR recording: overlays are left to the studio rather than baked in")
            Task { await engine.setOverlayProvider(nil) }
            return
        }
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

    @ObservationIgnored let countdown = CaptureCountdown()
    /// What the countdown is going to record, so "Start now" knows what to start.
    @ObservationIgnored var pendingTarget: RecordingTarget?

    @ObservationIgnored private var isWindowRecording = false
    /// Follows a recorded window so a click can be placed against where it was at the time.
    @ObservationIgnored var windowConverter: MovingWindowConverter?

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

        studio.start(
            recordsCamera: settings.recordingShowsWebcam,
            pointConverter: converter,
            pointPixelScale: Self.pointPixelScale(for: target)
        )
        observeClock()
        observeGeometry()
    }

    /// Feeds the recording's clock to the sidecar (docs/10 R0.1).
    ///
    /// Installed for every studio capture and nothing else. Without it the telemetry
    /// recorder's clock never moves: every click and chord is stamped zero, and the
    /// sample-rate gate — which asks whether enough time has passed since the last sample —
    /// compares zero against zero and refuses every pointer sample after the first.
    /// One long-lived consumer, not a `Task` per frame (docs/11 S2).
    ///
    /// This used to be `Task { @MainActor in studio.advance(to: time) }` inside the
    /// observer, which is sixty unstructured Tasks a second for the length of a recording —
    /// in the process with a 30 MB, 0%-CPU budget, on the same actor the event tap runs on.
    /// Worse than the cost: ordering between separately-created Tasks is not guaranteed, so
    /// the clock could go backwards, and the telemetry recorder's sample gate — which asks
    /// whether enough time has passed since the last sample — would then refuse everything
    /// until the clock caught up again.
    ///
    /// `.bufferingNewest(1)` is what makes this coalescing: if the main actor is busy, the
    /// frames that arrive meanwhile collapse to the most recent one, which is the only one
    /// whose answer is still true. Deliberately *not* throttled to a fixed rate — the clock
    /// is what stamps clicks and keystrokes, so quantising it to 10 Hz would put a ripple up
    /// to a tenth of a second away from the click that caused it, which is exactly the
    /// defect this sprint spent its first commit fixing.
    private func observeClock() {
        let (times, continuation) = AsyncStream<TimeInterval>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        clockContinuation = continuation
        clockTask = Task { @MainActor [weak self] in
            for await time in times {
                self?.studio.advance(to: time)
            }
        }
        Task { [weak self] in
            await self?.engine.setClockObserver { time in
                continuation.yield(time)
            }
        }
    }

    private func stopClockObserver() {
        clockContinuation?.finish()
        clockContinuation = nil
        clockTask?.cancel()
        clockTask = nil
        Task { [weak self] in await self?.engine.setClockObserver(nil) }
    }

    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var clockContinuation: AsyncStream<TimeInterval>.Continuation?

    /// Feeds the engine's content-rect changes to the sidecar and the converter.
    private func observeGeometry() {
        Task { [weak self] in
            // Only the live converter now (docs/11 S2). The same rect used to be
            // appended to a history in the sidecar as well — collected, copied, rebased on
            // every edit and persisted, and read by nothing. R3.1 replaced that pipeline
            // with normalise-at-capture and kept it running beside its replacement.
            await self?.engine.setGeometryObserver { [weak self] rect, scale, _ in
                Task { @MainActor [weak self] in
                    self?.windowConverter?.update(rect, scale: scale)
                }
            }
        }
    }

    /// Stops watching where the window is. The observer holds this coordinator, so leaving
    /// it attached after a recording keeps the engine pointed at a recording that is over.
    func stopGeometryObserver() {
        windowConverter = nil
        Task { [weak self] in await self?.engine.setGeometryObserver(nil) }
        stopClockObserver()
    }

    /// Tears every overlay monitor down. Called on stop, cancel and a failed start.
    func stopOverlays() {
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

    // MARK: - The clock the menu bar reads

    /// Ticks the elapsed time while recording.
    ///
    /// Kept beside the state rather than in the plumbing extension because it writes
    /// `elapsed`, whose setter is private to this file — and an extension that cannot
    /// reach the thing it exists to update is worse than no extension.
    func startTicking() {
        stopTicking()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let startedAt else { return }
                elapsed = Date().timeIntervalSince(startedAt) - pausedDuration
            }
        }
    }

    func stopTicking() {
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
