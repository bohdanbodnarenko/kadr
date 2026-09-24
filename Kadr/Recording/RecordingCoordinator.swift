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
    @ObservationIgnored let engine = RecordingEngine(
        segmentRoot: InterruptedRecordingStore.inProgressRoot()
    )
    @ObservationIgnored let captureEngine: CaptureEngine
    @ObservationIgnored let permissions: PermissionCoordinator
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let overlay: SelectionOverlayController
    @ObservationIgnored let hygiene: DesktopHygieneController?
    /// Click halos, keystrokes and the webcam. Started with the recording and stopped
    /// with it — none of its monitors exist while Kadr is idle (docs/03 §1.8).
    @ObservationIgnored let overlaySource = RecordingOverlaySource()
    /// The sidecar that makes a recording editable in the studio afterwards (docs/09 U3.1).
    ///
    /// Shares the camera recorder the picker warmed, so the live bubble and the camera
    /// file are one session rather than two devices fighting over the same webcam.
    @ObservationIgnored let studio: StudioSessionRecorder
    /// The script somebody reads from while recording (docs/08).
    @ObservationIgnored lazy var teleprompter = TeleprompterController(settings: settings)
    @ObservationIgnored let logger = KadrLog.logger(.recording)
    @ObservationIgnored let recovery = PermissionRecovery()

    /// What the status item shows.
    /// Setter is target-internal rather than file-private: the pause/stop/cancel half of
    /// this state machine lives in `RecordingCoordinator+Control.swift`, and this is the app
    /// target — nothing outside it can reach the coordinator at all.
    var state: RecordingState = .idle {
        didSet {
            onStateChanged?()
            // The bar and the menu-bar timer change silently; VoiceOver users need to hear
            // that the take began, paused or ended (docs/17 T-REC-11).
            if let message = RecordingAnnouncement.message(from: oldValue, to: state) {
                FeedbackAnnouncement.post(message)
            }
        }
    }

    /// Seconds recorded so far, pauses taken out.
    ///
    /// Deliberately *not* a trigger for `onStateChanged`. The tick writes this ten times a
    /// second so the meter can move, and every notification rebuilds the menu-bar icon and
    /// rewrites the floating bar — while the clock text only changes once a second. The
    /// tick asks `RecordingTickPolicy` whether anything a person can see has changed, and
    /// notifies only then.
    var elapsed: TimeInterval = 0

    /// Last-buffer loudness for the control bar meter (CleanShot §13.3).
    @ObservationIgnored var audioMeter = AudioMeter()
    /// When something was last audible, for the stop trim (docs/03 §1.8).
    @ObservationIgnored var lastAudibleTime: TimeInterval?

    /// Where the tick sends the meter level, ten times a second.
    ///
    /// A channel of its own rather than `onStateChanged`: the level feeds one small view in
    /// the floating bar, and routing it through the state change dragged the status item and
    /// every other control along with it (PRD §8).
    var onAudioLevel: ((Float) -> Void)?

    /// Whether the microphone is on but has picked nothing up this take.
    var microphoneIsSilent: Bool {
        RecordingTickPolicy.microphoneIsSilent(
            recordsMicrophone: microphoneThisTake,
            elapsed: elapsed,
            peak: microphonePeakMax
        )
    }

    /// Whether the resolved options for this take record the microphone.
    @ObservationIgnored var microphoneThisTake = false
    /// A device the take had to go without, shown on the bar once it is rolling.
    @ObservationIgnored var startNotice: String?
    /// Loudest microphone sample so far this take, for the silent-mic notice.
    @ObservationIgnored var microphonePeakMax: Float = 0

    /// Seconds left on the pre-roll, so the floating bar can show the same number as the overlay.
    var countdownRemaining = 0 {
        didSet { onStateChanged?() }
    }

    /// A finished recording, ready for the overlay.
    ///
    /// The Bool is true when this take was a dedicated GIF capture, so the overlay
    /// encodes a GIF instead of stopping at the MP4 card (CleanShot §13.6).
    var onFinished: ((RecordingResult, Bool) -> Void)?
    /// A finished recording that also has a studio session, so the editor can open it.
    var onStudioSessionReady: ((RecordingSession, RecordingResult) -> Void)?
    /// Fired whenever the state or the clock moves, so the menu bar can follow.
    var onStateChanged: (() -> Void)?
    @ObservationIgnored var terminationCompletion: (() -> Void)?
    /// Why the engine asked us to stop, if it did (docs/16 REC-1).
    @ObservationIgnored var pendingInterruption: String?
    @ObservationIgnored var engineEventsTask: Task<Void, Never>?
    /// Disables transport while start/pause/resume/stop is in flight (docs/16 REC-17).
    var isTransitioning = false {
        didSet { onStateChanged?() }
    }

    /// Transient bar copy while a take is being saved after an interruption (docs/16 REC-3).
    var liveNotice: String? {
        didSet { onStateChanged?() }
    }

    /// Ticks the elapsed time while recording.
    ///
    /// A Task, not a Timer, and only while a recording is running — the idle path still
    /// has none (PRD §8). 10 Hz so the audio meter can move; the clock text is still mm:ss.
    @ObservationIgnored var tickTask: Task<Void, Never>?
    @ObservationIgnored var startedAt: Date?
    @ObservationIgnored var pausedDuration: TimeInterval = 0
    @ObservationIgnored var pausedAt: Date?

    init(
        captureEngine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        overlay: SelectionOverlayController = SelectionOverlayController(),
        hygiene: DesktopHygieneController? = nil,
        camera: CameraFileRecorder = CameraFileRecorder()
    ) {
        self.captureEngine = captureEngine
        self.permissions = permissions
        self.settings = settings
        self.overlay = overlay
        self.hygiene = hygiene
        studio = StudioSessionRecorder(camera: camera)
        listenForEngineEvents()
    }

    /// Stream death and writer failure must stop the take and keep the footage
    /// (docs/16 REC-1/2).
    private func listenForEngineEvents() {
        engineEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in engine.events {
                handleEngineEvent(event)
            }
        }
    }

    func handleEngineEvent(_ event: RecordingEngineEvent) {
        guard state == .recording || state == .paused else { return }
        let message: String = switch event {
        case let .streamStopped(reason), let .writerFailed(reason):
            reason
        }
        pendingInterruption = message
        liveNotice = "Saving what was captured…"
        stop()
    }

    /// Whether a recording exists — including one still starting up.
    ///
    /// Everything that guards against a second recording asks this, so it has to be true
    /// for the whole life of one, not just the part after the stream is running.
    var isRecording: Bool {
        state.isActive && state != .finishing
    }

    /// Whether a take exists at all, saving included — what every *start* asks. A start during
    /// `.finishing` found the last take's studio session still attached (docs/17 T-REC-4).
    var isBusy: Bool {
        state.isActive
    }

    /// The window/area overlay is up to choose a recording target.
    var isSelectingTarget: Bool {
        overlay.isPresented
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
        if overrides.exportAsGIF {
            wantsGIFExport = true
        }
    }

    /// Whether the recording about to start was asked for by a script rather than a person.
    @ObservationIgnored var startedByAutomation = false
    /// Which call to `start` owns the recording being set up, so a failing start tears
    /// down only what it built and never a take that replaced it (docs/17 T-REC-3).
    @ObservationIgnored var startGeneration = 0
    /// The pause or resume in flight, so Stop can wait for it rather than race it
    /// (docs/17 T-REC-8).
    @ObservationIgnored var transportTask: Task<Void, Never>?
    /// Dedicated GIF capture (All-in-One G / `record-gif`): encode a GIF when this
    /// recording stops, instead of leaving only the MP4 card (CleanShot §13.6).
    @ObservationIgnored var wantsGIFExport = false

    /// Records a whole display, with no overlay.
    func beginDisplayRecording(_ displayID: CGDirectDisplayID = CGMainDisplayID()) {
        guard !state.isActive else { return }
        startAfterCountdown(target: .display(displayID))
    }

    /// - Parameter alreadyClaimed: true when a countdown has already moved the state to
    ///   `.starting` on this recording's behalf. Dropping back to `.idle` first would work,
    ///   but every observer sees that — the menu-bar icon and the floating bar both react to
    ///   the state, so the bar would be torn down and rebuilt in the same breath and the
    ///   user would watch it blink between the countdown ending and the recording starting.
    func start(target: RecordingTarget, alreadyClaimed: Bool = false) {
        guard recovery.allowCapture(permissions: permissions, includePicker: false) else {
            // A countdown claimed `.starting` for this take. Returning without handing the
            // claim back left a red "0:00" in the menu bar, live controls and the dim, all
            // for a recording that could never begin (docs/17 T-REC-2).
            if alreadyClaimed {
                abandonUnstartedRecording(reason: "Kadr needs Screen Recording permission to record.")
            }
            return
        }
        // Claimed synchronously, before the first await (docs/10 R0.3).
        //
        // Setting up a capture is a few hundred milliseconds of asking ScreenCaptureKit
        // for permission, content and a stream. `state` used to become `.recording` only
        // after all of it, so throughout that window the app reported itself idle, the
        // menu items stayed enabled, and a second press started a second recording — whose
        // failure path then ran `studio.cancel()`, deleting the *first* recording's session
        // directory, and put the desktop icons back while the first was still filming.
        if !alreadyClaimed {
            guard !state.isActive else { return }
            state = .starting
        }
        isTransitioning = true
        lastTarget = target
        startGeneration &+= 1
        let generation = startGeneration

        if case .window = target {
            isWindowRecording = true
        } else {
            isWindowRecording = false
        }
        let resolved = RecordingInputResolver.resolve(
            options: currentOptions,
            cameraDeviceID: settings.recordingCameraDeviceID,
            wantsCamera: settings.recordingShowsWebcam
        )
        let options = resolved.options
        // What this take really records, not what the settings asked for (T-REC-9).
        microphoneThisTake = options.recordsMicrophone
        startNotice = resolved.notice
        if let notice = resolved.notice {
            logger.info("\(notice, privacy: .public)")
        }
        Task { [weak self] in
            await self?.runEngineStart(
                target: target,
                options: options,
                cameraDeviceID: resolved.cameraDeviceID,
                generation: generation
            )
        }
    }

    /// The monthly Sequoia nag and a missing grant look the same to ScreenCaptureKit.
    /// Surface them here so a recording that never started is not a silent no-op.
    func presentPermissionRecoveryIfNeeded(_ error: any Error) {
        guard CaptureError.mapping(error).indicatesPermissionLoss else { return }
        switch recovery.present(state: permissions.state, includePicker: false) {
        case .openSettings:
            recovery.openSystemSettings()
        case .usePicker, .dismiss:
            break
        }
    }

    /// Whether this recording keeps a studio session beside it.
    var capturesStudioSession: Bool {
        settings.recordingCapturesStudioSession
    }

    @ObservationIgnored let countdown = CaptureCountdown()
    /// Dims the desk around a region recording so the frame is obvious while it runs.
    @ObservationIgnored let areaHighlight = RecordingAreaHighlight()
    /// What the countdown is going to record, so "Start now" knows what to start.
    @ObservationIgnored var pendingTarget: RecordingTarget?
    /// The source of the recording that is running (or just finished starting), so Restart
    /// can point at the same thing without asking again.
    @ObservationIgnored var lastTarget: RecordingTarget?

    @ObservationIgnored private var isWindowRecording = false
    /// Follows a recorded window so a click can be placed against where it was at the time.
    @ObservationIgnored var windowConverter: MovingWindowConverter?
    /// The recorded window's hole, so the dim can follow it when it moves.
    @ObservationIgnored var windowHighlightHole: DisplayRect?
    @ObservationIgnored var windowHighlightDisplayID: CGDirectDisplayID?

    /// Starts the studio sidecar, if this recording is keeping one.
    ///
    /// A window recording takes a different converter from a display or a region. Those sit
    /// still, so where a click lands on screen fixes where it lands in the frame once and
    /// for all. A window moves, so the same click means different things at different
    /// moments — and the converter has to ask the engine where the window is now rather
    /// than having been told once at the start.
    func startStudioSession(for target: RecordingTarget, cameraDeviceID: String? = nil) {
        guard capturesStudioSession else { return }

        var converter = Self.pointConverter(for: target)
        if isWindowRecording {
            let moving = MovingWindowConverter()
            windowConverter = moving
            converter = moving.converter()
        }

        let camera = cameraDeviceID ?? settings.recordingCameraDeviceID
        studio.start(
            recordsCamera: settings.recordingShowsWebcam && !camera.isEmpty,
            cameraDeviceID: camera,
            pointConverter: converter,
            pointPixelScale: Self.pointPixelScale(for: target, windowDisplay: windowHighlightDisplayID),
            topInset: Self.topInset(for: target)
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
                    if self?.isWindowRecording == true {
                        self?.followWindowHighlight(contentRect: rect)
                    }
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
        areaHighlight.hide()
        Task { await engine.setOverlayProvider(nil) }
    }
}
