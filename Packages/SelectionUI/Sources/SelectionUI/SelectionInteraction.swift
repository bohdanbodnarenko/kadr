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
    /// ⌘ — ignore the detected edges for this drag (docs/06 M21).
    public static let freeform = SelectionModifiers(rawValue: 1 << 2)
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

    /// The edges in the frozen image this selection snaps to (docs/06 M21).
    ///
    /// Set after detection finishes rather than at present time: finding the edges is one
    /// pass over a 5K bitmap, and the hotkey→overlay budget has no room for it (PRD §8).
    /// Until it arrives, dragging simply does not snap.
    public var snapping: SelectionSnapping?

    /// Optional width:height lock applied even without ⇧ (All-in-One / Settings).
    ///
    /// ⇧ still forces a square, which is the documented modifier and the override when a
    /// preset is on (docs/03 §1.1).
    public var lockedAspect: CGSize?

    /// True while Space is held, which turns a drag into a move (docs/03 §1.1).
    public private(set) var isMovingSelection = false
    /// True while the current rect is sitting on a detected edge (docs/14 D4 haptic).
    public private(set) var isAlignedToEdge = false
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
        isAlignedToEdge = false
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
            corner = fitted(from: anchor, towards: point, aspect: CGSize(width: 1, height: 1))
        } else if let lockedAspect {
            corner = fitted(from: anchor, towards: point, aspect: lockedAspect)
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
        let proposed = unclamped.intersection(bounds)
        let next = snapped(proposed, modifiers: modifiers)
        isAlignedToEdge = next != proposed
        rect = next
    }

    /// Applies edge snapping, unless the user asked for it not to be.
    ///
    /// ⌘ is the escape hatch: a snap that fights the user is worse than no snap, and a
    /// modifier they are already holding for other reasons would be the wrong choice.
    private func snapped(_ rect: CGRect, modifiers: SelectionModifiers) -> CGRect {
        guard let snapping,
              !modifiers.contains(.freeform),
              !modifiers.contains(.lockAspect),
              lockedAspect == nil
        else {
            return rect
        }
        return snapping.snapped(rect).intersection(bounds)
    }

    /// The smallest side a fresh drag must reach to count as a selection, in points.
    ///
    /// A click with a point or two of travel is a twitch, not a request for a 2×2 capture
    /// that replaces the clipboard (docs/18 CAP-3, docs/03 §1.1).
    public static let minimumSide: CGFloat = 4

    public mutating func end() {
        guard phase == .dragging else { return }
        let isLargeEnough = rect.map {
            $0.width >= Self.minimumSide && $0.height >= Self.minimumSide
        } ?? false
        phase = isLargeEnough ? .selected : .idle
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
        isAlignedToEdge = false
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
        // Re-anchor on the corner opposite the pointer, so continuing the drag resizes
        // from where the rect now is instead of snapping it to its top-left (T-CAP-12).
        if let rect, let pointer {
            anchor = Self.corner(of: rect, opposite: pointer)
        }
        moveOrigin = nil
        moveRectOrigin = nil
    }

    /// A press inside a committed selection: drag it along, keeping its size.
    ///
    /// Unlike `begin(at:)` this keeps the rect, so a click that does not move is a no-op
    /// rather than a reset — what confirm-selection mode needs (T-CAP-12).
    public mutating func beginMove(at point: CGPoint) {
        guard let rect, !rect.isEmpty else {
            begin(at: point)
            return
        }
        let point = clampToBounds(point)
        pointer = point
        anchor = rect.origin
        phase = .dragging
        isMovingSelection = true
        moveOrigin = point
        moveRectOrigin = rect.origin
    }

    /// The corner of `rect` farthest from `point`.
    static func corner(of rect: CGRect, opposite point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x >= rect.midX ? rect.minX : rect.maxX,
            y: point.y >= rect.midY ? rect.minY : rect.maxY
        )
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

    /// Replaces the current rect, keeping the selection committed.
    public mutating func setRect(_ newRect: CGRect) {
        guard !newRect.isEmpty else { return }
        let clamped = keepInsideBounds(newRect)
        if let snapping, !snapping.isEmpty {
            let next = snapping.snapped(clamped)
            isAlignedToEdge = next != clamped
            rect = next
        } else {
            isAlignedToEdge = false
            rect = clamped
        }
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

    /// The far corner of an aspect-locked drag, keeping the direction the user is dragging.
    private func fitted(from anchor: CGPoint, towards point: CGPoint, aspect: CGSize) -> CGPoint {
        let ratio = max(aspect.width, 0.001) / max(aspect.height, 0.001)
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        var width = abs(dx)
        var height = abs(dy)
        if height < 0.001 || width / height > ratio {
            height = width / ratio
        } else {
            width = height * ratio
        }
        return CGPoint(
            x: anchor.x + (dx >= 0 ? width : -width),
            y: anchor.y + (dy >= 0 ? height : -height)
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
