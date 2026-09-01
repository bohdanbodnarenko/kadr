import CoreGraphics
import Foundation

/// Where the webcam sits over the recording (docs/09 U3.4).
///
/// The camera is recorded to its own file rather than composited live, which is what makes
/// all of this editable after the fact: position, size and shape are decisions the user can
/// change — or reverse entirely — without re-recording anything. A bubble burned into the
/// screen recording is a bubble nobody can move.
public struct CameraBubble: Sendable, Hashable, Codable {
    /// Which corner it sits in, when `center` is nil.
    public var placement: BubblePlacement
    /// How big, as a fraction of the frame's shortest edge — normalized like every other
    /// metric in Kadr, so a layout carries between a 1080p and a 4K export.
    public var sizeFraction: Double
    /// How far from the edges, likewise normalized.
    public var marginFraction: Double
    /// 0 is a rectangle, 1 is a circle.
    public var roundness: Double
    /// Whether to show it at all. Kept rather than removed so turning the camera off and
    /// on again restores the layout the user set.
    public var isVisible: Bool
    /// Normalized (0…1, top-left) centre. Nil means snap to `placement`, the way a
    /// corner picker works. A drag on the preview writes this so the bubble can sit
    /// anywhere, not only in nine slots.
    public var center: CGPoint?

    public init(
        placement: BubblePlacement = .bottomTrailing,
        sizeFraction: Double = 0.22,
        marginFraction: Double = 0.03,
        roundness: Double = 1,
        isVisible: Bool = true,
        center: CGPoint? = nil
    ) {
        self.placement = placement
        self.sizeFraction = min(max(sizeFraction, 0.05), 0.6)
        self.marginFraction = min(max(marginFraction, 0), 0.2)
        self.roundness = min(max(roundness, 0), 1)
        self.isVisible = isVisible
        self.center = center.map(Self.clampedCenter)
    }

    /// A circle in the corner: the layout almost everybody wants.
    public static let standard = CameraBubble()
    /// A rounded rectangle, for somebody who wants to see the whole frame.
    public static let rectangle = CameraBubble(sizeFraction: 0.26, roundness: 0.2)
    /// Filling the frame, for a talking-head recording.
    public static let full = CameraBubble(placement: .centre, sizeFraction: 0.6, marginFraction: 0, roundness: 0)

    /// The bubble's frame in a video of `size`.
    public func frame(in size: CGSize) -> CGRect {
        let shortest = max(min(size.width, size.height), 1)
        let side = shortest * sizeFraction
        if let center {
            let maxX = max(size.width - side, 0)
            let maxY = max(size.height - side, 0)
            return CGRect(
                x: min(max(center.x * size.width - side / 2, 0), maxX),
                y: min(max(center.y * size.height - side / 2, 0), maxY),
                width: side,
                height: side
            )
        }
        let margin = shortest * marginFraction
        let box = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)

        return CGRect(
            x: box.minX + (box.width - side) * placement.horizontalBias,
            y: box.minY + (box.height - side) * placement.verticalBias,
            width: side,
            height: side
        )
    }

    /// The centre of `frame(in:)`, as a fraction of `size`.
    public func normalizedCenter(in size: CGSize) -> CGPoint {
        let frame = frame(in: size)
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: frame.midX / size.width, y: frame.midY / size.height)
    }

    /// Snaps back to a named corner and forgets a free position.
    public mutating func snap(to placement: BubblePlacement) {
        self.placement = placement
        center = nil
    }

    /// Places the bubble by dragging, and updates `placement` so the corner picker
    /// follows the nearest slot.
    public mutating func move(toNormalizedCenter point: CGPoint) {
        let clamped = Self.clampedCenter(point)
        center = clamped
        placement = BubblePlacement.nearest(to: clamped)
    }

    /// Grows or shrinks around a pinned corner, so a handle drag does not shove the
    /// opposite edge across the frame.
    public mutating func resize(
        toSizeFraction value: Double,
        pinningTopLeading origin: CGPoint,
        in size: CGSize
    ) {
        sizeFraction = min(max(value, 0.05), 0.6)
        let side = max(min(size.width, size.height), 1) * sizeFraction
        guard size.width > 0, size.height > 0 else { return }
        move(toNormalizedCenter: CGPoint(
            x: (origin.x + side / 2) / size.width,
            y: (origin.y + side / 2) / size.height
        ))
    }

    private static func clampedCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x.isFinite ? point.x : 0.5, 0), 1),
            y: min(max(point.y.isFinite ? point.y : 0.5, 0), 1)
        )
    }

    /// The corner radius for that frame.
    public func cornerRadius(in size: CGSize) -> CGFloat {
        frame(in: size).width / 2 * roundness
    }

    private enum CodingKeys: String, CodingKey {
        case placement, sizeFraction, marginFraction, roundness, isVisible, center
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            placement: container.decodeIfPresent(BubblePlacement.self, forKey: .placement)
                ?? .bottomTrailing,
            sizeFraction: container.decodeIfPresent(Double.self, forKey: .sizeFraction) ?? 0.22,
            marginFraction: container.decodeIfPresent(Double.self, forKey: .marginFraction) ?? 0.03,
            roundness: container.decodeIfPresent(Double.self, forKey: .roundness) ?? 1,
            isVisible: container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
            center: container.decodeIfPresent(CGPoint.self, forKey: .center)
        )
    }
}

/// The nine positions a bubble can take.
public enum BubblePlacement: String, Sendable, Hashable, Codable, CaseIterable {
    case topLeading, top, topTrailing
    case leading, centre, trailing
    case bottomLeading, bottom, bottomTrailing

    public var horizontalBias: CGFloat {
        switch self {
        case .topLeading, .leading, .bottomLeading: 0
        case .top, .centre, .bottom: 0.5
        case .topTrailing, .trailing, .bottomTrailing: 1
        }
    }

    public var verticalBias: CGFloat {
        switch self {
        case .topLeading, .top, .topTrailing: 0
        case .leading, .centre, .trailing: 0.5
        case .bottomLeading, .bottom, .bottomTrailing: 1
        }
    }

    /// The nine-slot neighbour of a free position, so a drag still has a named corner.
    public static func nearest(to center: CGPoint) -> BubblePlacement {
        allCases.min { left, right in
            hypot(left.horizontalBias - center.x, left.verticalBias - center.y)
                < hypot(right.horizontalBias - center.x, right.verticalBias - center.y)
        } ?? .bottomTrailing
    }

    public var title: String {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top"
        case .topTrailing: "Top Right"
        case .leading: "Left"
        case .centre: "Centre"
        case .trailing: "Right"
        case .bottomLeading: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomTrailing: "Bottom Right"
        }
    }
}
