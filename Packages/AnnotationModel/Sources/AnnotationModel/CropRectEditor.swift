import CoreGraphics
import Foundation

/// Which part of a crop rectangle a drag has hold of (docs/09 U1.8).
public enum CropHandle: String, Codable, CaseIterable, Sendable {
    case topLeading, top, topTrailing
    case leading, trailing
    case bottomLeading, bottom, bottomTrailing
    /// The inside of the rect: dragging moves the whole thing.
    case body

    /// Whether this handle moves the given edge.
    public func moves(_ edge: CropEdge) -> Bool {
        switch edge {
        case .top: [.topLeading, .top, .topTrailing].contains(self)
        case .bottom: [.bottomLeading, .bottom, .bottomTrailing].contains(self)
        case .leading: [.topLeading, .leading, .bottomLeading].contains(self)
        case .trailing: [.topTrailing, .trailing, .bottomTrailing].contains(self)
        }
    }

    /// The corner diagonally opposite, which is what an aspect-locked resize pivots about.
    ///
    /// Anchoring at the opposite corner rather than at the centre is what makes a locked
    /// resize feel like dragging a corner: the corner under the pointer follows it and
    /// nothing else moves. Centre-anchored, both corners move and the rect appears to
    /// slide away from the pointer.
    public var oppositeCorner: CropHandle? {
        switch self {
        case .topLeading: .bottomTrailing
        case .topTrailing: .bottomLeading
        case .bottomLeading: .topTrailing
        case .bottomTrailing: .topLeading
        default: nil
        }
    }

    public var isCorner: Bool {
        oppositeCorner != nil
    }

    /// The eight anchors around a selection or crop, excluding the body.
    public static let resizeHandles: [CropHandle] = allCases.filter { $0 != .body }

    /// Where this handle sits on a rect.
    public func point(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * horizontalBias,
            y: rect.minY + rect.height * verticalBias
        )
    }

    private var horizontalBias: CGFloat {
        switch self {
        case .topLeading, .leading, .bottomLeading: 0
        case .top, .bottom, .body: 0.5
        case .topTrailing, .trailing, .bottomTrailing: 1
        }
    }

    private var verticalBias: CGFloat {
        switch self {
        case .topLeading, .top, .topTrailing: 0
        case .leading, .trailing, .body: 0.5
        case .bottomLeading, .bottom, .bottomTrailing: 1
        }
    }
}

public enum CropEdge: CaseIterable, Sendable {
    case top, bottom, leading, trailing
}

/// The arithmetic of dragging a crop rectangle (docs/09 U1.8).
///
/// Pure and separate from the view, because this is the part with the interesting rules —
/// aspect locking, minimum sizes, whether the rect may leave the image — and none of them
/// need a window to check. It is also the part shared by the crop tool and, eventually, by
/// anything else that drags a rectangle around.
public enum CropRectEditor {
    /// How small a crop may get before the handles start overlapping each other.
    public static let minimumSize: CGFloat = 16
    /// How close the pointer has to be to a handle to grab it rather than the body.
    public static let handleTolerance: CGFloat = 10

    /// The handle under `point`, if any.
    ///
    /// Corners are tested before edges, and edges before the body: at a corner all three
    /// are candidates, and the corner is the one the user is aiming at.
    public static func handle(
        at point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat = handleTolerance
    ) -> CropHandle? {
        let corners: [CropHandle] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
        let edges: [CropHandle] = [.top, .bottom, .leading, .trailing]

        for handle in corners + edges {
            let anchor = handle.point(in: rect)
            if abs(point.x - anchor.x) <= tolerance, abs(point.y - anchor.y) <= tolerance {
                return handle
            }
        }
        return rect.contains(point) ? .body : nil
    }

    /// The rect after a drag.
    ///
    /// - Parameters:
    ///   - rect: the rect as it was when the drag began.
    ///   - handle: what the drag has hold of.
    ///   - translation: how far the pointer has moved since the drag began.
    ///   - aspect: a width-over-height ratio to hold, or nil for a free resize.
    ///   - bounds: the area the rect may not leave, or nil to let it go anywhere — which
    ///     is what expand-canvas means (docs/03 §3).
    public static func resized(
        _ rect: CGRect,
        handle: CropHandle,
        translation: CGSize,
        aspect: CGFloat? = nil,
        bounds: CGRect? = nil,
        fromCenter: Bool = false
    ) -> CGRect {
        if fromCenter, handle != .body {
            return resizedFromCenter(
                rect,
                handle: handle,
                translation: translation,
                aspect: aspect,
                bounds: bounds
            )
        }
        guard handle != .body else {
            return moved(rect, by: translation, within: bounds)
        }

        var edges = (
            minX: rect.minX,
            minY: rect.minY,
            maxX: rect.maxX,
            maxY: rect.maxY
        )
        if handle.moves(.leading) {
            edges.minX += translation.width
        }
        if handle.moves(.trailing) {
            edges.maxX += translation.width
        }
        if handle.moves(.top) {
            edges.minY += translation.height
        }
        if handle.moves(.bottom) {
            edges.maxY += translation.height
        }

        var resized = CGRect(
            x: min(edges.minX, edges.maxX),
            y: min(edges.minY, edges.maxY),
            width: abs(edges.maxX - edges.minX),
            height: abs(edges.maxY - edges.minY)
        )
        resized = enforcingMinimum(resized, handle: handle)
        if let aspect, aspect > 0 {
            resized = holding(aspect, on: resized, handle: handle)
        }
        if let bounds {
            resized = clamped(resized, to: bounds, handle: handle, aspect: aspect)
        }
        return resized
    }

    private static func resizedFromCenter(
        _ rect: CGRect,
        handle: CropHandle,
        translation: CGSize,
        aspect: CGFloat?,
        bounds: CGRect?
    ) -> CGRect {
        var edges = (
            minX: rect.minX,
            minY: rect.minY,
            maxX: rect.maxX,
            maxY: rect.maxY
        )
        if handle.moves(.leading) || handle.moves(.trailing) {
            edges.minX -= translation.width
            edges.maxX += translation.width
        }
        if handle.moves(.top) || handle.moves(.bottom) {
            edges.minY -= translation.height
            edges.maxY += translation.height
        }
        var resized = CGRect(
            x: min(edges.minX, edges.maxX),
            y: min(edges.minY, edges.maxY),
            width: abs(edges.maxX - edges.minX),
            height: abs(edges.maxY - edges.minY)
        )
        resized = enforcingMinimum(resized, handle: handle)
        if let aspect, aspect > 0 {
            resized = holding(aspect, on: resized, handle: handle)
        }
        if let bounds {
            resized = clamped(resized, to: bounds, handle: handle, aspect: aspect)
        }
        return resized
    }

    /// Moves the whole rect, keeping it inside `bounds` if there is one.
    static func moved(_ rect: CGRect, by translation: CGSize, within bounds: CGRect?) -> CGRect {
        var moved = rect.offsetBy(dx: translation.width, dy: translation.height)
        guard let bounds else { return moved }
        // Slide back in rather than refuse: a drag that runs into the edge should stop
        // there, not stick where it was.
        moved.origin.x = min(max(moved.minX, bounds.minX), max(bounds.maxX - moved.width, bounds.minX))
        moved.origin.y = min(max(moved.minY, bounds.minY), max(bounds.maxY - moved.height, bounds.minY))
        return moved
    }

    /// Grows the rect back to the minimum, away from whichever edge the handle is holding.
    static func enforcingMinimum(_ rect: CGRect, handle: CropHandle) -> CGRect {
        var rect = rect
        if rect.width < minimumSize {
            // The edge that is *not* moving stays put.
            if handle.moves(.leading) {
                rect.origin.x = rect.maxX - minimumSize
            }
            rect.size.width = minimumSize
        }
        if rect.height < minimumSize {
            if handle.moves(.top) {
                rect.origin.y = rect.maxY - minimumSize
            }
            rect.size.height = minimumSize
        }
        return rect
    }

    /// Reshapes the rect to `aspect`, pivoting on the corner opposite the handle.
    ///
    /// The dimension that changed most is the one the user is driving, so the other is
    /// derived from it — which keeps a locked drag tracking the pointer along whichever
    /// axis they are actually moving.
    static func holding(_ aspect: CGFloat, on rect: CGRect, handle: CropHandle) -> CGRect {
        var width = rect.width
        var height = rect.height

        if handle == .leading || handle == .trailing {
            height = width / aspect
        } else if handle == .top || handle == .bottom {
            width = height * aspect
        } else if width / max(height, 0.001) > aspect {
            height = width / aspect
        } else {
            width = height * aspect
        }
        width = max(width, minimumSize)
        height = max(height, minimumSize)

        // Pivot on the fixed corner: the one the pointer is not holding.
        let anchor = (handle.oppositeCorner ?? .topLeading).point(in: rect)
        let x = handle.moves(.leading) ? anchor.x - width : anchor.x
        let y = handle.moves(.top) ? anchor.y - height : anchor.y
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Keeps the rect inside `bounds`, preserving the aspect ratio if one is being held.
    static func clamped(
        _ rect: CGRect,
        to bounds: CGRect,
        handle: CropHandle,
        aspect: CGFloat?
    ) -> CGRect {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull else { return bounds }
        guard let aspect, aspect > 0 else {
            return intersection
        }
        // With a ratio to hold, shrink to fit rather than crop to fit — cropping the rect
        // to the bounds would break the ratio the user asked for.
        let scale = min(intersection.width / rect.width, intersection.height / rect.height)
        let width = max(rect.width * scale, minimumSize)
        let height = max(rect.height * scale, minimumSize)
        let anchor = (handle.oppositeCorner ?? .topLeading).point(in: rect)
        let x = handle.moves(.leading) ? anchor.x - width : anchor.x
        let y = handle.moves(.top) ? anchor.y - height : anchor.y
        return CGRect(x: x, y: y, width: width, height: height).intersection(bounds)
    }
}

/// Ratios the crop tool offers (docs/09 U1.8).
public enum CropAspectPreset: String, Codable, CaseIterable, Sendable {
    case free
    case original
    case square
    case fourThree
    case threeTwo
    case sixteenNine
    case nineSixteen
    case fourFive

    public var title: String {
        switch self {
        case .free: String(localized: "Free", bundle: .module)
        case .original: String(localized: "Original", bundle: .module)
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        case .fourFive: "4:5"
        }
    }

    /// Width over height, given what the capture's own ratio is.
    public func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: original.height > 0 ? original.width / original.height : nil
        case .square: 1
        case .fourThree: 4 / 3
        case .threeTwo: 3 / 2
        case .sixteenNine: 16 / 9
        case .nineSixteen: 9 / 16
        case .fourFive: 4 / 5
        }
    }
}
