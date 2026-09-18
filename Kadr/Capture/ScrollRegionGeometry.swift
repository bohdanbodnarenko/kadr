import CoreGraphics

/// What a press on the scrolling-capture frame grabs, and what dragging it does
/// (docs/03 §1.6).
///
/// View-local AppKit coordinates throughout: points, origin bottom-left. Pure, so the
/// hit-testing and the resize arithmetic are tested with tables rather than a mouse.
nonisolated enum ScrollRegionGeometry {
    enum Horizontal: Equatable, Sendable {
        case left
        case right
    }

    enum Vertical: Equatable, Sendable {
        case bottom
        case top
    }

    enum Target: Equatable, Sendable {
        /// A corner or an edge; nil on an axis means that axis does not move.
        case resize(Horizontal?, Vertical?)
        /// The grip on the top edge.
        case move
    }

    /// How far from a corner still counts as the corner.
    static let cornerReach: CGFloat = 14
    /// How thick the grabbable band along each edge is.
    ///
    /// Eight points, not five: this band is the only thing between the page underneath and
    /// a resize, and a five-point target on a frame the size of a window is a target people
    /// miss, scroll the page with, and have to line up again.
    static let edgeReach: CGFloat = 8
    /// The bar that moves the frame, across its whole width.
    static let moveBarHeight: CGFloat = 26
    static let minimumSize = CGSize(width: 80, height: 60)
    /// The handles drawn on the frame: four corners and four edge midpoints.
    static let handleDiameter: CGFloat = 10

    /// The bar that moves the frame: full width, above it, like a window's title bar.
    ///
    /// It used to be a 56×16 grip centred on the top edge — a target smaller than a
    /// scrollbar, sitting *on* the line people were trying to grab to resize. Above the
    /// frame rather than on it, so it covers none of the content being lined up, and it
    /// flips inside the top edge when the frame is against the top of the screen.
    static func moveBar(for rect: CGRect, in bounds: CGRect) -> CGRect {
        let above = rect.maxY + 2
        let fitsAbove = above + moveBarHeight <= bounds.maxY
        return CGRect(
            x: rect.minX,
            y: fitsAbove ? above : max(rect.maxY - moveBarHeight, rect.minY),
            width: rect.width,
            height: moveBarHeight
        )
    }

    /// Where a press lands on the frame, or nil for anywhere that should pass through.
    static func target(at point: CGPoint, in rect: CGRect, bounds: CGRect) -> Target? {
        if moveBar(for: rect, in: bounds).contains(point) {
            return .move
        }
        let nearLeft = abs(point.x - rect.minX) <= cornerReach
        let nearRight = abs(point.x - rect.maxX) <= cornerReach
        let nearBottom = abs(point.y - rect.minY) <= cornerReach
        let nearTop = abs(point.y - rect.maxY) <= cornerReach
        let horizontal: Horizontal? = nearLeft ? .left : nearRight ? .right : nil
        let vertical: Vertical? = nearBottom ? .bottom : nearTop ? .top : nil
        if let horizontal, let vertical {
            return .resize(horizontal, vertical)
        }

        let withinX = point.x >= rect.minX - edgeReach && point.x <= rect.maxX + edgeReach
        let withinY = point.y >= rect.minY - edgeReach && point.y <= rect.maxY + edgeReach
        if withinY, abs(point.x - rect.minX) <= edgeReach {
            return .resize(.left, nil)
        }
        if withinY, abs(point.x - rect.maxX) <= edgeReach {
            return .resize(.right, nil)
        }
        if withinX, abs(point.y - rect.minY) <= edgeReach {
            return .resize(nil, .bottom)
        }
        if withinX, abs(point.y - rect.maxY) <= edgeReach {
            return .resize(nil, .top)
        }
        return nil
    }

    /// Everything that takes clicks: the edge bands, the corners and the move bar. The
    /// inside and the outside pass through to the apps underneath, which is what lets the
    /// page be scrolled into place while the frame is being set.
    static func interactiveRects(for rect: CGRect, in bounds: CGRect) -> [CGRect] {
        let reach = max(cornerReach, edgeReach)
        return [
            CGRect(x: rect.minX - reach, y: rect.minY - reach, width: reach * 2, height: rect.height + reach * 2),
            CGRect(x: rect.maxX - reach, y: rect.minY - reach, width: reach * 2, height: rect.height + reach * 2),
            CGRect(x: rect.minX - reach, y: rect.minY - reach, width: rect.width + reach * 2, height: reach * 2),
            CGRect(x: rect.minX - reach, y: rect.maxY - reach, width: rect.width + reach * 2, height: reach * 2),
            moveBar(for: rect, in: bounds)
        ]
    }

    /// The frame after dragging `target` by `delta` from where it started.
    ///
    /// Kept inside `bounds` and never smaller than `minimumSize`; an edge dragged past its
    /// opposite stops at the minimum rather than flipping the frame inside out.
    static func dragged(
        _ start: CGRect,
        target: Target,
        by delta: CGVector,
        in bounds: CGRect
    ) -> CGRect {
        switch target {
        case .move:
            let x = min(max(start.minX + delta.dx, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + delta.dy, bounds.minY), bounds.maxY - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        case let .resize(horizontal, vertical):
            var minX = start.minX
            var maxX = start.maxX
            var minY = start.minY
            var maxY = start.maxY
            switch horizontal {
            case .left:
                minX = min(max(start.minX + delta.dx, bounds.minX), maxX - minimumSize.width)
            case .right:
                maxX = max(min(start.maxX + delta.dx, bounds.maxX), minX + minimumSize.width)
            case nil:
                break
            }
            switch vertical {
            case .bottom:
                minY = min(max(start.minY + delta.dy, bounds.minY), maxY - minimumSize.height)
            case .top:
                maxY = max(min(start.maxY + delta.dy, bounds.maxY), minY + minimumSize.height)
            case nil:
                break
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// The most of the screen a frame nobody has sized yet may take.
    ///
    /// A maximised window used to hand back a frame the size of the screen, whose edges are
    /// against the screen's edges — nowhere to grab, nothing to drag it by, and a resize
    /// that has to start by making it smaller from a corner three pixels from the Dock.
    static let initialFraction: CGFloat = 0.72

    /// The frame to start from: the window under the pointer, kept to a size that can be
    /// grabbed, else a generous centred area — always inside the visible part of the screen.
    static func initialRect(window: CGRect?, visible: CGRect) -> CGRect {
        let ceiling = CGSize(
            width: (visible.width * initialFraction).rounded(),
            height: (visible.height * initialFraction).rounded()
        )
        if let window {
            let clipped = window.intersection(visible)
            if !clipped.isNull, clipped.width >= minimumSize.width, clipped.height >= minimumSize.height {
                return centred(
                    CGSize(width: min(clipped.width, ceiling.width), height: min(clipped.height, ceiling.height)),
                    on: CGPoint(x: clipped.midX, y: clipped.midY),
                    in: visible
                )
            }
        }
        return centred(ceiling, on: CGPoint(x: visible.midX, y: visible.midY), in: visible)
    }

    /// A size placed around a point, nudged back inside `visible` if it would hang off.
    static func centred(_ size: CGSize, on point: CGPoint, in visible: CGRect) -> CGRect {
        let width = min(max(size.width, minimumSize.width), visible.width)
        let height = min(max(size.height, minimumSize.height), visible.height)
        let x = min(max(point.x - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(point.y - height / 2, visible.minY), visible.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Whether a remembered frame still makes sense on this screen.
    static func fits(_ rect: CGRect, in visible: CGRect) -> Bool {
        rect.width >= minimumSize.width
            && rect.height >= minimumSize.height
            && visible.insetBy(dx: -1, dy: -1).contains(rect)
    }

    /// The eight handle centres, corners first.
    static func handleCentres(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)
        ]
    }
}
