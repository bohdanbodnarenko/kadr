import CoreGraphics
import Shared

/// Modifier keys the selection cares about (docs/03 §1.1).
public struct SelectionModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// ⌥ — resize around the anchor instead of from it.
    public static let fromCenter = SelectionModifiers(rawValue: 1 << 0)
    /// ⇧ — lock to a square.
    public static let lockAspect = SelectionModifiers(rawValue: 1 << 1)
}

public enum NudgeDirection: Sendable, Hashable, CaseIterable {
    case left, right, up, down

    /// A unit step in display space, where y grows downwards.
    var offset: CGSize {
        switch self {
        case .left: CGSize(width: -1, height: 0)
        case .right: CGSize(width: 1, height: 0)
        case .up: CGSize(width: 0, height: -1)
        case .down: CGSize(width: 0, height: 1)
        }
    }
}

/// The selection's interaction state machine (docs/03 §1.1).
///
/// Deliberately free of AppKit: this is where every rule about what the selection rect
/// *is* lives — dragging, ⌥ from centre, ⇧ square, Space to move, arrow nudges, typed
/// sizes — so all of it can be tested without a window server, and so the view layer has
/// nothing to do but draw the answer.
///
/// Coordinates are display-local points with a **top-left origin**, matching display
/// space and the flipped view the overlay draws into.
public struct SelectionInteraction: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing selected yet; the crosshair is following the pointer.
        case idle
        /// The mouse is down and the rect is being dragged out.
        case dragging
        /// The mouse is up and a rect exists.
        case selected
    }

    /// The display's bounds; the selection can never leave them.
    public let bounds: CGRect

    public private(set) var phase: Phase = .idle
    /// Where the drag started, in display-local points.
    public private(set) var anchor: CGPoint?
    /// The current pointer position, used for the crosshair and the loupe.
    public private(set) var pointer: CGPoint?
    public private(set) var rect: CGRect?

    /// True while Space is held, which turns a drag into a move (docs/03 §1.1).
    public private(set) var isMovingSelection = false
    private var moveOrigin: CGPoint?
    private var moveRectOrigin: CGPoint?

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    // MARK: - Pointer

    public mutating func pointerMoved(to point: CGPoint) {
        pointer = clampToBounds(point)
    }

    public mutating func begin(at point: CGPoint) {
        let point = clampToBounds(point)
        anchor = point
        pointer = point
        rect = CGRect(origin: point, size: .zero)
        phase = .dragging
    }

    public mutating func drag(to point: CGPoint, modifiers: SelectionModifiers = []) {
        guard phase == .dragging, let anchor else { return }
        let point = clampToBounds(point)
        pointer = point

        if isMovingSelection {
            moveDuringDrag(to: point)
            return
        }

        var corner = point
        if modifiers.contains(.lockAspect) {
            corner = squared(from: anchor, towards: point)
        }

        let unclamped = if modifiers.contains(.fromCenter) {
            CGRect(
                x: anchor.x - (corner.x - anchor.x),
                y: anchor.y - (corner.y - anchor.y),
                width: abs(corner.x - anchor.x) * 2,
                height: abs(corner.y - anchor.y) * 2
            )
        } else {
            CGRect(
                x: min(anchor.x, corner.x),
                y: min(anchor.y, corner.y),
                width: abs(corner.x - anchor.x),
                height: abs(corner.y - anchor.y)
            )
        }
        rect = unclamped.intersection(bounds)
    }

    public mutating func end() {
        guard phase == .dragging else { return }
        phase = (rect?.isEmpty == false) ? .selected : .idle
        if phase == .idle {
            rect = nil
        }
        isMovingSelection = false
        moveOrigin = nil
        moveRectOrigin = nil
    }

    /// Esc: back to nothing, ready for a fresh drag.
    public mutating func cancelSelection() {
        phase = .idle
        rect = nil
        anchor = nil
        isMovingSelection = false
        moveOrigin = nil
        moveRectOrigin = nil
    }

    // MARK: - Space to move (docs/03 §1.1)

    /// Space held during a drag: the rect keeps its size and follows the pointer.
    public mutating func beginMovingSelection() {
        guard phase == .dragging, let rect, let pointer else { return }
        isMovingSelection = true
        moveOrigin = pointer
        moveRectOrigin = rect.origin
    }

    public mutating func endMovingSelection() {
        guard isMovingSelection else { return }
        isMovingSelection = false
        // Re-anchor so continuing the drag resizes from the rect's far corner rather
        // than jumping back to where the drag originally started.
        if let rect {
            anchor = CGPoint(x: rect.minX, y: rect.minY)
        }
        moveOrigin = nil
        moveRectOrigin = nil
    }

    private mutating func moveDuringDrag(to point: CGPoint) {
        guard let moveOrigin, let moveRectOrigin, let size = rect?.size else { return }
        let proposed = CGRect(
            x: moveRectOrigin.x + (point.x - moveOrigin.x),
            y: moveRectOrigin.y + (point.y - moveOrigin.y),
            width: size.width,
            height: size.height
        )
        rect = keepInsideBounds(proposed)
    }

    /// Moves an existing selection by a delta, keeping its size.
    public mutating func move(by delta: CGSize) {
        guard let rect else { return }
        self.rect = keepInsideBounds(rect.offsetBy(dx: delta.width, dy: delta.height))
    }

    // MARK: - Keyboard

    /// Arrow keys: 1 point, or 10 with ⇧ (docs/03 §1.1).
    public mutating func nudge(_ direction: NudgeDirection, coarse: Bool = false) {
        let step: CGFloat = coarse ? 10 : 1
        let offset = direction.offset
        move(by: CGSize(width: offset.width * step, height: offset.height * step))
    }

    /// Arrow keys with the selection being resized rather than moved.
    public mutating func resize(_ direction: NudgeDirection, coarse: Bool = false) {
        guard let rect else { return }
        let step: CGFloat = coarse ? 10 : 1
        let offset = direction.offset
        let proposed = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(1, rect.width + offset.width * step),
            height: max(1, rect.height + offset.height * step)
        )
        self.rect = proposed.intersection(bounds)
    }

    /// A typed exact size, applied from the selection's top-left corner (docs/03 §1.1).
    ///
    /// With nothing selected the size is applied from the pointer, so typing a size is a
    /// complete way to make a selection rather than only a way to adjust one.
    public mutating func setSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let origin = rect?.origin ?? pointer ?? bounds.origin
        rect = keepInsideBounds(CGRect(origin: origin, size: size))
        phase = .selected
    }

    /// Selects the whole display.
    public mutating func selectAll() {
        rect = bounds
        phase = .selected
    }

    // MARK: - Geometry helpers

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// Slides a rect back inside the display without changing its size, then trims it if
    /// it is simply too big to fit.
    private func keepInsideBounds(_ rect: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(result.minX, bounds.minX), max(bounds.minX, bounds.maxX - result.width))
        result.origin.y = min(max(result.minY, bounds.minY), max(bounds.minY, bounds.maxY - result.height))
        return result.intersection(bounds)
    }

    /// The corner that makes the drag square, keeping the direction the user is dragging.
    private func squared(from anchor: CGPoint, towards point: CGPoint) -> CGPoint {
        let side = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
        return CGPoint(
            x: anchor.x + (point.x >= anchor.x ? side : -side),
            y: anchor.y + (point.y >= anchor.y ? side : -side)
        )
    }
}

public extension SelectionInteraction {
    /// The selection in global display space, ready for `CaptureEngine.captureRegion`.
    func globalRect(on display: DisplayGeometry) -> DisplayRect? {
        guard let rect, !rect.isEmpty else { return nil }
        return DisplayRect(
            x: display.frame.minX + rect.minX,
            y: display.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }
}
