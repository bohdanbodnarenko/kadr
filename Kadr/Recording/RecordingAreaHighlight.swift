import AppKit
import OverlayKit
import RecordingCore
import Shared

/// Dims everything outside a region recording so the frame stays visible (docs/03 §1.8).
///
/// Click-through and capture-excluded: it is a reminder, not a control, and it must never
/// appear in the footage it is describing. Sits just below the floating bar so the dim
/// does not wash out Skip, Pause or Stop.
@MainActor
final class RecordingAreaHighlight {
    private static let dimLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    private var panel: NonActivatingPanel?
    private var lastDisplayID: CGDirectDisplayID?

    var isShowing: Bool {
        panel != nil
    }

    /// Shows the dim if `target` is a region, and hides it otherwise.
    func show(for target: RecordingTarget) {
        switch target {
        case let .region(rect, displayID):
            show(region: rect, displayID: displayID)
        case .display, .window:
            hide()
        }
    }

    /// Dims everything outside a window being recorded, including after it moves.
    func showWindow(hole: DisplayRect, displayID: CGDirectDisplayID) {
        show(region: hole, displayID: displayID)
    }

    func show(region: DisplayRect, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ScreenDescriptor($0)?.displayID == displayID
        }) ?? NSScreen.main else {
            return
        }
        let hole = Self.holeRect(region, on: screen)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        if lastDisplayID == displayID, let panel, let root = panel.contentView?.layer {
            panel.setFrame(screen.frame, display: false)
            panel.contentView?.frame = bounds
            root.sublayers = nil
            installChrome(in: root, bounds: bounds, hole: hole, scale: screen.backingScaleFactor)
            lastDisplayID = displayID
            return
        }
        present(on: screen, bounds: bounds, hole: hole, displayID: displayID)
    }

    func hide() {
        lastDisplayID = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Even-odd path: the screen, with the recorded rect punched out.
    nonisolated static func dimPath(bounds: CGRect, hole: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(hole.intersection(bounds))
        return path
    }

    static func holeRect(_ region: DisplayRect, on screen: NSScreen) -> CGRect {
        let space = GlobalCoordinateSpace.current
        return region.inScreenSpace(space).cgRect.offsetBy(
            dx: -screen.frame.minX,
            dy: -screen.frame.minY
        )
    }

    private func installChrome(in root: CALayer, bounds: CGRect, hole: CGRect, scale: CGFloat) {
        let dim = CAShapeLayer()
        dim.frame = bounds
        dim.path = Self.dimPath(bounds: bounds, hole: hole)
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        root.addSublayer(dim)

        let border = CAShapeLayer()
        border.frame = bounds
        border.path = CGPath(rect: hole.intersection(bounds), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        border.lineWidth = 2
        border.contentsScale = scale
        root.addSublayer(border)
    }

    private func present(on screen: NSScreen, bounds: CGRect, hole: CGRect, displayID: CGDirectDisplayID) {
        hide()
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        guard let root = view.layer else { return }
        installChrome(in: root, bounds: bounds, hole: hole, scale: screen.backingScaleFactor)

        let panel = NonActivatingPanel(contentRect: screen.frame, level: Self.dimLevel)
        panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        lastDisplayID = displayID
    }
}
