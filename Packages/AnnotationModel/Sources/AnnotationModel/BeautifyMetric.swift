import CoreGraphics
import Foundation

/// A length expressed as a fraction of the capture's shortest edge (docs/09 U1.1).
///
/// The problem it solves: "48 points of padding" is generous around a 400-point tweet
/// screenshot and invisible around a 3000-point 5K capture. A preset built on one looks
/// wrong on the other, which makes presets nearly useless — the thing they exist to do is
/// carry a *look* between captures.
///
/// A fraction of the shortest edge carries instead. 0.08 is "a bit less than a tenth of
/// the narrow side", and that reads the same at any size. The shortest edge rather than the
/// area or the diagonal because padding, radius and shadow all read against the nearest
/// edge — a wide panorama should not get panoramic padding.
///
/// Absolute lengths remain expressible (`.points`), because a user who types 12 px means
/// 12 px. They simply do not scale.
public enum BeautifyMetric: Codable, Hashable, Sendable {
    /// A fraction of the shortest edge of the content being decorated.
    case relative(CGFloat)
    /// An exact length in points.
    case points(CGFloat)

    /// The length this resolves to for content whose shortest edge is `shortestEdge`.
    public func resolved(shortestEdge: CGFloat) -> CGFloat {
        switch self {
        case let .relative(fraction): max(0, fraction) * max(shortestEdge, 0)
        case let .points(length): max(0, length)
        }
    }

    /// The fraction this represents for a given content size, for showing in a slider that
    /// works in fractions whatever the stored form is.
    public func fraction(shortestEdge: CGFloat) -> CGFloat {
        guard shortestEdge > 0 else { return 0 }
        return resolved(shortestEdge: shortestEdge) / shortestEdge
    }

    public static let zero = BeautifyMetric.points(0)

    public var isZero: Bool {
        switch self {
        case let .relative(fraction): fraction <= 0
        case let .points(length): length <= 0
        }
    }

    // MARK: - Codable

    /// Encoded as a single-key object so a future third form can be added without a
    /// migration, and decoded permissively so documents written before this type existed —
    /// where these fields were bare numbers of points — still open (docs/08 §2.6).
    private enum CodingKeys: String, CodingKey {
        case relative, points
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let length = try? single.decode(CGFloat.self) {
            self = .points(length)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let fraction = try container.decodeIfPresent(CGFloat.self, forKey: .relative) {
            self = .relative(fraction)
        } else if let length = try container.decodeIfPresent(CGFloat.self, forKey: .points) {
            self = .points(length)
        } else {
            self = .zero
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .relative(fraction): try container.encode(fraction, forKey: .relative)
        case let .points(length): try container.encode(length, forKey: .points)
        }
    }
}

/// Where the capture sits inside its canvas (docs/09 U1.1).
///
/// Nine positions rather than a free offset because the useful compositions are the nine —
/// and because the interesting behaviour is what happens at the edges, which needs to know
/// *which* edges are touched.
public enum BeautifyAlignment: String, Codable, CaseIterable, Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    /// Horizontal placement, 0 at the leading edge and 1 at the trailing edge.
    public var horizontalBias: CGFloat {
        switch self {
        case .topLeading, .leading, .bottomLeading: 0
        case .top, .center, .bottom: 0.5
        case .topTrailing, .trailing, .bottomTrailing: 1
        }
    }

    /// Vertical placement, 0 at the top and 1 at the bottom, in the model's top-left space.
    public var verticalBias: CGFloat {
        switch self {
        case .topLeading, .top, .topTrailing: 0
        case .leading, .center, .trailing: 0.5
        case .bottomLeading, .bottom, .bottomTrailing: 1
        }
    }

    public var title: String {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top"
        case .topTrailing: "Top Right"
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        case .bottomLeading: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomTrailing: "Bottom Right"
        }
    }
}

/// Which edges a stuck alignment presses the capture against (docs/09 U1.1).
///
/// "Stuck" is the CleanShot look where the screenshot bleeds off the bottom of the frame
/// rather than floating in the middle of it: the padding on the touched edges goes to zero
/// and the corners that meet them square off. Modelled as a set because a corner alignment
/// sticks two edges at once, and the corner between them is the one that squares.
public struct BeautifyEdges: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let top = BeautifyEdges(rawValue: 1 << 0)
    public static let leading = BeautifyEdges(rawValue: 1 << 1)
    public static let bottom = BeautifyEdges(rawValue: 1 << 2)
    public static let trailing = BeautifyEdges(rawValue: 1 << 3)
    public static let none: BeautifyEdges = []

    /// The edges an alignment presses against, when sticking is on.
    public static func stuck(by alignment: BeautifyAlignment) -> BeautifyEdges {
        var edges = BeautifyEdges.none
        if alignment.verticalBias == 0 {
            edges.insert(.top)
        }
        if alignment.verticalBias == 1 {
            edges.insert(.bottom)
        }
        if alignment.horizontalBias == 0 {
            edges.insert(.leading)
        }
        if alignment.horizontalBias == 1 {
            edges.insert(.trailing)
        }
        return edges
    }
}

/// Four corner radii, so a stuck corner can square off while the others stay round.
public struct BeautifyCorners: Equatable, Sendable {
    public var topLeading: CGFloat
    public var topTrailing: CGFloat
    public var bottomTrailing: CGFloat
    public var bottomLeading: CGFloat

    public init(
        topLeading: CGFloat,
        topTrailing: CGFloat,
        bottomTrailing: CGFloat,
        bottomLeading: CGFloat
    ) {
        self.topLeading = max(topLeading, 0)
        self.topTrailing = max(topTrailing, 0)
        self.bottomTrailing = max(bottomTrailing, 0)
        self.bottomLeading = max(bottomLeading, 0)
    }

    public init(uniform radius: CGFloat) {
        self.init(
            topLeading: radius,
            topTrailing: radius,
            bottomTrailing: radius,
            bottomLeading: radius
        )
    }

    public static let square = BeautifyCorners(uniform: 0)

    public var isUniform: Bool {
        topLeading == topTrailing && topTrailing == bottomTrailing && bottomTrailing == bottomLeading
    }

    public var largest: CGFloat {
        max(max(topLeading, topTrailing), max(bottomTrailing, bottomLeading))
    }

    /// A corner squares off when *either* of its edges is stuck.
    ///
    /// Either, not both: a capture stuck to the bottom edge has both its bottom corners on
    /// the canvas boundary, and a rounded corner sitting on the boundary shows a notch of
    /// background where the capture should be running off the edge. Requiring both edges
    /// would leave those notches and only square anything at the four corner alignments.
    public static func resolving(radius: CGFloat, stuck edges: BeautifyEdges) -> BeautifyCorners {
        func corner(_ first: BeautifyEdges, _ second: BeautifyEdges) -> CGFloat {
            edges.contains(first) || edges.contains(second) ? 0 : radius
        }
        return BeautifyCorners(
            topLeading: corner(.top, .leading),
            topTrailing: corner(.top, .trailing),
            bottomTrailing: corner(.bottom, .trailing),
            bottomLeading: corner(.bottom, .leading)
        )
    }

    /// Each radius reduced by `amount`, floored at zero — the inner curve of a ring whose
    /// outer curve is this one.
    public func inset(by amount: CGFloat) -> BeautifyCorners {
        BeautifyCorners(
            topLeading: topLeading - amount,
            topTrailing: topTrailing - amount,
            bottomTrailing: bottomTrailing - amount,
            bottomLeading: bottomLeading - amount
        )
    }

    /// Clamped so no radius exceeds half the shorter side of `rect`.
    public func clamped(to rect: CGRect) -> BeautifyCorners {
        let limit = min(rect.width, rect.height) / 2
        return BeautifyCorners(
            topLeading: min(topLeading, limit),
            topTrailing: min(topTrailing, limit),
            bottomTrailing: min(bottomTrailing, limit),
            bottomLeading: min(bottomLeading, limit)
        )
    }
}
