import CoreGraphics
import Shared

/// A window the overlay can highlight and capture (docs/03 §1.2).
///
/// Its frame is in **display-local points**, already mapped onto the display the overlay
/// is drawn on, so hit-testing is a plain rect test against pointer coordinates.
public struct PickableWindow: Sendable, Hashable, Identifiable {
    public let id: CGWindowID
    public let title: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    /// ScreenCaptureKit window layer. Zero is a normal window; 1…8 are panels (docs/03 §1.2).
    public let layer: Int
    /// The window's frame in display-local points.
    public let frame: CGRect

    public init(
        id: CGWindowID,
        title: String?,
        applicationName: String?,
        bundleIdentifier: String?,
        layer: Int = 0,
        frame: CGRect
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.frame = frame
    }

    /// A child window or panel, offered only while ⌘ is held (docs/03 §1.2).
    public var isAuxiliary: Bool {
        layer >= 1 && layer <= 8
    }

    /// What the title chip shows: the app name, plus the window title when it adds
    /// something. Untitled windows are common and "Safari — " reads badly.
    public var label: String {
        switch (applicationName, title?.isEmpty == false ? title : nil) {
        case let (app?, windowTitle?) where app != windowTitle: "\(app) — \(windowTitle)"
        case let (app?, _): app
        case let (nil, windowTitle?): windowTitle
        default: "Window \(id)"
        }
    }
}

/// Window-pick mode's state (docs/03 §1.2).
///
/// Kept apart from the view for the same reason as `SelectionInteraction`: hit-testing
/// order, Tab cycling and the "same app" rule are behaviour worth testing, and none of
/// it needs a screen.
public struct WindowPickInteraction: Equatable, Sendable {
    /// Windows in front-to-back order, which hit-testing relies on. `CaptureEngine`
    /// sorts them by the window server's stack (`WindowStackOrder`); ScreenCaptureKit's
    /// own list is not in that order.
    public private(set) var windows: [PickableWindow]
    public private(set) var hoveredID: CGWindowID?
    /// When false, auxiliary windows (layer 1…8) are hidden until ⌘ is held.
    public var includesAuxiliaryWindows = false

    public init(windows: [PickableWindow] = []) {
        self.windows = windows
    }

    private var visibleWindows: [PickableWindow] {
        guard includesAuxiliaryWindows else {
            return windows.filter { !$0.isAuxiliary }
        }
        return windows
    }

    public var hovered: PickableWindow? {
        guard let hoveredID else { return nil }
        return windows.first { $0.id == hoveredID }
    }

    public mutating func setWindows(_ windows: [PickableWindow]) {
        self.windows = windows
        if let hoveredID, !windows.contains(where: { $0.id == hoveredID }) {
            self.hoveredID = nil
        }
    }

    /// Updates the hover to the frontmost window under the pointer.
    ///
    /// Returns true when the highlight changed, so the caller can skip redrawing on the
    /// vast majority of mouse-moved events that stay inside the same window.
    @discardableResult
    public mutating func pointerMoved(to point: CGPoint) -> Bool {
        let hit = window(at: point)?.id
        guard hit != hoveredID else { return false }
        hoveredID = hit
        return true
    }

    /// The frontmost window containing a point.
    public func window(at point: CGPoint) -> PickableWindow? {
        visibleWindows.first { $0.frame.contains(point) }
    }

    /// ⇥ moves to the next window of the same app (docs/03 §1.2).
    ///
    /// With nothing hovered, or with only one window from that app, it steps through
    /// every window instead — otherwise Tab would appear broken.
    @discardableResult
    public mutating func cycle(reverse: Bool = false) -> PickableWindow? {
        let visible = visibleWindows
        guard !visible.isEmpty else { return nil }

        guard let hovered else {
            hoveredID = visible.first?.id
            return hovered
        }

        let sameApp = visible.filter { $0.bundleIdentifier == hovered.bundleIdentifier }
        let pool = sameApp.count > 1 ? sameApp : visible
        guard let index = pool.firstIndex(of: hovered) else {
            hoveredID = pool.first?.id
            return self.hovered
        }

        let step = reverse ? -1 : 1
        let next = (index + step + pool.count) % pool.count
        hoveredID = pool[next].id
        return self.hovered
    }

    public mutating func clearHover() {
        hoveredID = nil
    }
}

/// A window offered for picking, in global display space.
///
/// This is what callers hand over — from `CaptureEngine.shareableContent()`, already front
/// to back — and the overlay maps it onto whichever displays show it.
public struct PickableWindowDescriptor: Sendable, Hashable {
    public let id: CGWindowID
    public let title: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let layer: Int
    public let globalFrame: DisplayRect

    public init(
        id: CGWindowID,
        title: String?,
        applicationName: String?,
        bundleIdentifier: String?,
        layer: Int = 0,
        globalFrame: DisplayRect
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.globalFrame = globalFrame
    }

    /// Rebases onto one display's local coordinates, or `nil` when the window is not on
    /// that display at all.
    ///
    /// A window straddling two displays maps onto both, with coordinates running off the
    /// edge — which is exactly what makes the highlight line up with the visible part.
    public func mapped(onto display: DisplayGeometry) -> PickableWindow? {
        guard display.frame.intersects(globalFrame) else { return nil }
        return PickableWindow(
            id: id,
            title: title,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            layer: layer,
            frame: display.localRect(for: globalFrame).cgRect
        )
    }
}
