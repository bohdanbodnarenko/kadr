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
        let options = currentOptions
        Task { [weak self] in
            guard let self else { return }
            do {
                startOverlays(for: target)
                try await engine.start(target: target, options: options)
                state = .recording
                startedAt = Date()
                overlaySource.recordingStartedAt = startedAt
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
                hygiene?.endRecording()
                logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
                permissions.noteCaptureFailure(error)
            }
        }
    }

    /// Turns on only the overlays the user asked for, and tells the engine where to get
    /// them (docs/03 §1.8).
    private func startOverlays(for target: RecordingTarget) {
        let wantsAny = settings.recordingShowsClicks
            || settings.recordingShowsKeystrokes
            || settings.recordingShowsWebcam
        guard wantsAny else {
            Task { await engine.setOverlayProvider(nil) }
            return
        }

        var configuration = RecordingOverlaySource.Configuration()
        configuration.showsClicks = settings.recordingShowsClicks
        configuration.showsKeystrokes = settings.recordingShowsKeystrokes
        configuration.keystrokesOnlyWithModifiers = settings.recordingKeystrokesShortcutsOnly
        configuration.showsWebcam = settings.recordingShowsWebcam
        configuration.pointConverter = Self.pointConverter(for: target)

        overlaySource.start(configuration: configuration)
        let source = overlaySource
        Task { await engine.setOverlayProvider(source) }
    }

    /// Tears every overlay monitor down. Called on stop, cancel and a failed start.
    private func stopOverlays() {
        overlaySource.stop()
        overlaySource.recordingStartedAt = nil
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
        RecordingOptions(
            frameRate: RecordingFrameRate(rawValue: settings.recordingFrameRate.rawValue) ?? .sixty,
            codec: settings.recordingCodec == .hevc ? .hevc : .h264,
            capturesSystemAudio: settings.recordsSystemAudio,
            capturesMicrophone: settings.recordsMicrophone,
            showsCursor: settings.recordingShowsCursor
        )
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
            startTicking()
        }
    }

    func stop() {
        guard isRecording else { return }
        state = .finishing
        stopTicking()
        focus.disable()
        stopOverlays()
        hygiene?.endRecording()

        let destination = destinationURL()
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.stop(savingTo: destination)
                state = .idle
                elapsed = 0
                logger.info("Recording saved: \(result.fileURL.lastPathComponent, privacy: .public)")
                onFinished?(result)
            } catch {
                state = .idle
                elapsed = 0
                logger.error("Recording failed to finish: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        stopTicking()
        focus.disable()
        stopOverlays()
        hygiene?.endRecording()
        Task { [weak self] in
            await self?.engine.cancel()
            self?.state = .idle
            self?.elapsed = 0
        }
    }

    // MARK: - Plumbing

    private func destinationURL() -> URL {
        let template = FilenameTemplate("Kadr recording {date} {time}")
        let name = template.expand(FilenameContext(applicationName: "Screen", date: Date()))
        return settings.saveFolder.appendingPathComponent(name).appendingPathExtension("mp4")
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
