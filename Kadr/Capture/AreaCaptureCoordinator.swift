import AppKit
import CaptureCore
import os
import SelectionUI
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
    private let output = CaptureOutput()
    private let logger = KadrLog.logger(.capture)
    private let signposter = KadrLog.signposter(.capture)

    private var inFlight: Task<Void, Never>?

    /// The last committed region, for "capture previous area" (docs/03 §1.1).
    private var lastRegion: (rect: DisplayRect, displayID: CGDirectDisplayID)?

    init(
        engine: CaptureEngine,
        permissions: PermissionCoordinator,
        overlay: SelectionOverlayController = SelectionOverlayController()
    ) {
        self.engine = engine
        self.permissions = permissions
        self.overlay = overlay
    }

    var hasPreviousRegion: Bool {
        lastRegion != nil
    }

    /// Freezes every display and puts the selection overlay up.
    func beginAreaCapture() {
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

                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    signpostState: interval
                ) { [weak self] result in
                    self?.finish(with: result, freezes: freezes)
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
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await engine.captureRegion(lastRegion.rect, on: lastRegion.displayID)
                permissions.noteCaptureSuccess()
                output.copyToClipboard(capture.image)
            } catch {
                handle(error)
            }
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        overlay.cancel()
    }

    // MARK: - Completion

    private func finish(with result: SelectionResult?, freezes: [DisplayFreeze]) {
        guard let result else {
            logger.info("Area capture cancelled")
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

        lastRegion = (result.rect, result.display.displayID)
        output.copyToClipboard(image)
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
