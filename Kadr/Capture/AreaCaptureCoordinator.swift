import AppKit
import CaptureCore
import os
import SelectionUI
import SettingsKit
import Shared

/// Drives area capture end to end: hotkey → freeze → overlay → crop → clipboard.
///
/// The whole flow is one `Task` tree hung off the initiating command (docs/04 §8), so
/// Esc or a second hotkey cancels everything in flight rather than leaving a freeze
/// half-finished.
@MainActor
final class AreaCaptureCoordinator {
    private let engine: CaptureEngine
    private let permissions: PermissionCoordinator
    private let overlay: SelectionOverlayController
    private let settings: AppSettings
    private let timer = CaptureCountdown()
    private let output = CaptureOutput()
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    private var inFlight: Task<Void, Never>?

    /// The last committed region, for "capture previous area" (docs/03 §1.1).
    private var lastRegion: (rect: DisplayRect, displayID: CGDirectDisplayID)?

    init(
        engine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        overlay: SelectionOverlayController = SelectionOverlayController()
    ) {
        self.engine = engine
        self.permissions = permissions
        self.settings = settings
        self.overlay = overlay
    }

    var hasPreviousRegion: Bool {
        lastRegion != nil
    }

    /// Freezes every display and puts the selection overlay up.
    func beginAreaCapture() {
        beginOverlayCapture(mode: .area)
    }

    /// Freezes every display and opens window-pick mode (docs/03 §1.2).
    func beginWindowCapture() {
        beginOverlayCapture(mode: .window)
    }

    /// Captures every display with no overlay at all (docs/03 §1.3).
    func captureAllDisplays() {
        inFlight?.cancel()
        let seconds = settings.timerSeconds
        timer.run(seconds: seconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    let captures = try await engine.captureAllDisplays(
                        includesCursor: settings.includesCursor
                    )
                    permissions.noteCaptureSuccess()
                    output.deliver(captures)
                } catch {
                    handle(error)
                }
            }
        }
    }

    private func beginOverlayCapture(mode: SelectionMode) {
        // A second hotkey re-freezes rather than stacking overlays (docs/03 §1.1).
        inFlight?.cancel()

        // Opened here so the interval covers the freeze, which is the expensive half of
        // the < 100 ms hotkey-to-overlay budget (PRD §8).
        let interval = signposter.beginInterval("hotkeyToOverlay")

        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let freezes = try await engine.freezeAllDisplays()
                guard !Task.isCancelled else { return }
                permissions.noteCaptureSuccess()

                let windows: [PickableWindowDescriptor] = if mode == .window {
                    try await engine.shareableContent().windows
                        .filter(\.isUserWindow)
                        .map {
                            PickableWindowDescriptor(
                                id: $0.id,
                                title: $0.title,
                                applicationName: $0.applicationName,
                                bundleIdentifier: $0.bundleIdentifier,
                                globalFrame: $0.frame
                            )
                        }
                } else {
                    []
                }

                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    mode: mode,
                    windows: windows,
                    signpostState: interval
                ) { [weak self] outcome in
                    self?.finish(with: outcome, freezes: freezes)
                }
            } catch {
                signposter.endInterval("hotkeyToOverlay", interval)
                handle(error)
            }
        }
    }

    /// Repeats the last region with no UI at all (docs/03 §1.1).
    func capturePreviousArea() {
        guard let lastRegion else {
            logger.info("No previous area to capture yet")
            return
        }

        inFlight?.cancel()
        let region = lastRegion
        timer.run(seconds: settings.timerSeconds) { [weak self] in
            self?.captureRegionLive(region.rect, on: region.displayID)
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        timer.cancel()
        overlay.cancel()
    }

    // MARK: - Completion

    private func finish(with outcome: SelectionOutcome?, freezes: [DisplayFreeze]) {
        switch outcome {
        case nil:
            logger.info("Capture cancelled")
        case let .region(result):
            finishRegion(result, freezes: freezes)
        case let .window(selection):
            finishWindow(selection)
        }
    }

    /// Captures the picked window through SCK, so it comes out unoccluded rather than
    /// cropped out of the frozen screen (docs/03 §1.2).
    private func finishWindow(_ selection: WindowSelection) {
        let shadow = selection.togglesShadow ? !settings.windowShadow : settings.windowShadow
        let options = WindowCaptureOptions(
            includesShadow: shadow,
            transparentBackground: settings.transparentWindowBackground,
            includesCursor: settings.includesCursor
        )

        timer.run(seconds: settings.timerSeconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    let capture = try await engine.captureWindow(selection.window.id, options: options)
                    permissions.noteCaptureSuccess()
                    output.copyToClipboard(capture.image)
                } catch {
                    handle(error)
                }
            }
        }
    }

    private func finishRegion(_ result: SelectionResult, freezes: [DisplayFreeze]) {
        lastRegion = (result.rect, result.display.displayID)

        // With a timer running the point is to capture what the screen looks like *after*
        // the countdown, so the frozen image is the wrong source and the region is
        // re-captured live (docs/03 §1.5). Without a timer, cropping the freeze is both
        // faster and the only way to guarantee WYSIWYG (docs/03 §1.1).
        guard settings.timerSeconds == 0 else {
            timer.run(seconds: settings.timerSeconds) { [weak self] in
                self?.captureRegionLive(result.rect, on: result.display.displayID)
            }
            return
        }

        let state = signposter.beginInterval("selectionToClipboard")
        defer { signposter.endInterval("selectionToClipboard", state) }

        guard let freeze = freezes.first(where: { $0.geometry.displayID == result.display.displayID }) else {
            logger.error("The selected display's freeze went missing")
            return
        }

        // Cropped from the frozen bitmap, never re-captured — that is what guarantees
        // the file matches what the user selected on (docs/03 §1.1).
        let frozen = FrozenDisplay(geometry: freeze.geometry, image: freeze.image)
        guard let image = frozen.croppedImage(localRect: result.localRect) else {
            logger.error("Could not crop the selection out of the frozen image")
            return
        }

        output.copyToClipboard(image)
    }

    private func captureRegionLive(_ rect: DisplayRect, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await engine.captureRegion(
                    rect,
                    on: displayID,
                    includesCursor: settings.includesCursor
                )
                permissions.noteCaptureSuccess()
                output.copyToClipboard(capture.image)
            } catch {
                handle(error)
            }
        }
    }

    private func handle(_ error: any Error) {
        if error is CancellationError {
            return
        }
        permissions.noteCaptureFailure(error)
        let mapped = CaptureError.mapping(error)
        logger.error("Area capture failed: \(mapped.errorDescription ?? "unknown", privacy: .public)")
    }
}
