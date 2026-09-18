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
    static let cornerReach: CGFloat = 10
    /// How thick the grabbable band along each edge is.
    static let edgeReach: CGFloat = 5
    static let gripSize = CGSize(width: 56, height: 16)
    static let minimumSize = CGSize(width: 80, height: 60)
    /// The handles drawn on the frame: four corners and four edge midpoints.
    static let handleDiameter: CGFloat = 9

    /// The move grip, centred on the top edge.
    static func grip(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.midX - gripSize.width / 2,
            y: rect.maxY - gripSize.height / 2,
            width: gripSize.width,
            height: gripSize.height
        )
    }

    /// Where a press lands on the frame, or nil for anywhere that should pass through.
    static func target(at point: CGPoint, in rect: CGRect) -> Target? {
        if grip(for: rect).contains(point) {
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

    /// Everything that takes clicks: the edge bands, the corners and the grip. The inside
    /// and the outside pass through to the apps underneath.
    static func interactiveRects(for rect: CGRect) -> [CGRect] {
        let reach = max(cornerReach, edgeReach)
        return [
            CGRect(x: rect.minX - reach, y: rect.minY - reach, width: reach * 2, height: rect.height + reach * 2),
            CGRect(x: rect.maxX - reach, y: rect.minY - reach, width: reach * 2, height: rect.height + reach * 2),
            CGRect(x: rect.minX - reach, y: rect.minY - reach, width: rect.width + reach * 2, height: reach * 2),
            CGRect(x: rect.minX - reach, y: rect.maxY - reach, width: rect.width + reach * 2, height: reach * 2),
            grip(for: rect)
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

    /// The frame to start from: the window under the pointer when there is one, else a
    /// generous centred area — always inside the visible part of the screen.
    static func initialRect(window: CGRect?, visible: CGRect) -> CGRect {
        if let window {
            let clipped = window.intersection(visible)
            if !clipped.isNull, clipped.width >= minimumSize.width, clipped.height >= minimumSize.height {
                return clipped.integral
            }
        }
        let width = (visible.width * 0.6).rounded()
        let height = (visible.height * 0.7).rounded()
        return CGRect(
            x: (visible.midX - width / 2).rounded(),
            y: (visible.midY - height / 2).rounded(),
            width: width,
            height: height
        )
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
