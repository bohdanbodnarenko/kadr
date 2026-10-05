import AppKit
import CaptureCore
import OverlayKit
import Shared

/// The adjustable frame a scrolling capture starts from (docs/03 §1.6).
///
/// Shown over the live screen, around the window under the pointer. The page stays
/// scrollable underneath so it can be lined up first; Start (or Return) begins, and while
/// the capture runs the frame stays, locked, with the rest of the screen dimmed.
@MainActor
extension ScrollCaptureCoordinator {
    func presentEditor(on screen: NSScreen, aroundWindow window: ScreenRect?) {
        let editor = ScrollRegionEditor(screen: screen)
        editor.onStart = { [weak self] rect in
            self?.startStaged(rect, auto: false)
        }
        editor.onStartAuto = { [weak self] rect in
            self?.startStaged(rect, auto: true)
        }
        editor.onCancel = { [weak self] in
            self?.stage = nil
            self?.finish(nil)
        }
        stage = editor
        editor.present(aroundWindow: window)
    }

    /// Begins the capture the frame was set for, either tier.
    private func startStaged(_ rect: DisplayRect, auto: Bool) {
        guard let display = Self.geometry(for: rect) else {
            dismissStage()
            finish(nil)
            return
        }
        if auto || usesAutoScroll {
            confirmAutoScrollTrust()
        }
        start(region: rect, display: display, auto: auto)
    }

    /// Asks about Accessibility before any frame is grabbed, once, rather than with a
    /// system prompt and an alert stacked on a running capture (T-CAP-10).
    private func confirmAutoScrollTrust() {
        guard !AutoScroller.isTrusted else { return }
        explainAccessibility()
    }

    func dismissStage() {
        stage?.dismiss()
        stage = nil
    }

    /// The frontmost ordinary window under the pointer on `screen`, in AppKit screen space.
    ///
    /// Asked of the engine's snapshot, which is already front to back
    /// (`WindowStackOrder`), so the first hit is the one the user is looking at.
    func windowUnderPointer(on screen: NSScreen) async -> ScreenRect? {
        let space = GlobalCoordinateSpace.current
        let pointer = ScreenPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
            .inDisplaySpace(space)
        guard let windows = try? await captureEngine.shareableContent().windows else { return nil }
        let hit = windows.first { window in
            window.isUserWindow && window.frame.cgRect.contains(CGPoint(x: pointer.x, y: pointer.y))
        }
        guard let hit else { return nil }
        let rect = hit.frame.inScreenSpace(space)
        return screen.frame.intersects(rect.cgRect) ? rect : nil
    }

    /// The display a global rect sits on, as the capture session needs it.
    static func geometry(for rect: DisplayRect) -> DisplayGeometry? {
        guard let displayID = DisplayLookup.display(containing: rect) else { return nil }
        return DisplayGeometry(
            displayID: displayID,
            frame: DisplayRect(cgRect: CGDisplayBounds(displayID)),
            scale: NSScreen.screens.compactMap(ScreenDescriptor.init)
                .first { $0.displayID == displayID }?.scale ?? .oneToOne
        )
    }
}

// MARK: - Interruption

@MainActor
extension ScrollCaptureCoordinator {
    /// macOS ended the stream mid-capture: stitch what there is and say why it stopped,
    /// rather than leave a HUD counting frames that will never come (docs/18 CAP-8).
    func streamInterrupted() {
        guard state == .capturing else { return }
        FailurePresenter.present(FeedbackStatus(
            kind: .warning,
            message: "macOS stopped the scrolling capture. Kadr kept the frames it had."
        ))
        stop()
    }
}
