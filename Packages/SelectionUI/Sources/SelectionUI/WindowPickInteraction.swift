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
    /// The window's frame in display-local points.
    public let frame: CGRect

    public init(
        id: CGWindowID,
        title: String?,
        applicationName: String?,
        bundleIdentifier: String?,
        frame: CGRect
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
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
    /// Windows in front-to-back order, which is the order `SCShareableContent` returns
    /// them in and the order hit-testing must respect.
    public private(set) var windows: [PickableWindow]
    public private(set) var hoveredID: CGWindowID?

    public init(windows: [PickableWindow] = []) {
        self.windows = windows
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
        windows.first { $0.frame.contains(point) }
    }

    /// ⇥ moves to the next window of the same app (docs/03 §1.2).
    ///
    /// With nothing hovered, or with only one window from that app, it steps through
    /// every window instead — otherwise Tab would appear broken.
    @discardableResult
    public mutating func cycle(reverse: Bool = false) -> PickableWindow? {
        guard !windows.isEmpty else { return nil }

        guard let hovered else {
            hoveredID = windows.first?.id
            return hovered
        }

        let sameApp = windows.filter { $0.bundleIdentifier == hovered.bundleIdentifier }
        let pool = sameApp.count > 1 ? sameApp : windows
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
/// This is what callers hand over — straight out of `SCShareableContent` — and the
/// overlay maps it onto whichever displays show it.
public struct PickableWindowDescriptor: Sendable, Hashable {
    public let id: CGWindowID
    public let title: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let globalFrame: DisplayRect

    public init(
        id: CGWindowID,
        title: String?,
        applicationName: String?,
        bundleIdentifier: String?,
        globalFrame: DisplayRect
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
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
            frame: display.localRect(for: globalFrame).cgRect
        )
    }
}
