import CoreGraphics
import Foundation

/// A gradient with an optional middle stop (docs/09 U1.1).
///
/// Two-stop gradients between saturated colours pass through a muddy midpoint, because
/// linear interpolation in sRGB cuts the corner of the colour solid. A third stop is how
/// every designed gradient avoids that, and it is why a curated set can look better than
/// anything the user assembles from two colour wells.
public struct BeautifyGradient: Codable, Hashable, Sendable {
    public var start: AnnotationColor
    /// The middle stop, and where along the gradient it sits. Nil is a plain two-stop ramp.
    public var middle: AnnotationColor?
    public var middleLocation: CGFloat
    public var end: AnnotationColor
    /// Measured from the positive x-axis, clockwise in the model's top-left space, so 90 is
    /// top to bottom.
    public var angleDegrees: CGFloat

    public init(
        start: AnnotationColor,
        middle: AnnotationColor? = nil,
        middleLocation: CGFloat = 0.5,
        end: AnnotationColor,
        angleDegrees: CGFloat = 90
    ) {
        self.start = start
        self.middle = middle
        self.middleLocation = min(max(middleLocation, 0.01), 0.99)
        self.end = end
        self.angleDegrees = angleDegrees
    }

    /// The stops as the renderer wants them: colours and locations, in order.
    public var stops: [(color: AnnotationColor, location: CGFloat)] {
        guard let middle else {
            return [(start, 0), (end, 1)]
        }
        return [(start, 0), (middle, middleLocation), (end, 1)]
    }

    /// Older documents stored `start`, `end` and an angle with no middle stop.
    private enum CodingKeys: String, CodingKey {
        case start, middle, middleLocation, end, angleDegrees
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(AnnotationColor.self, forKey: .start)
        end = try container.decode(AnnotationColor.self, forKey: .end)
        middle = try container.decodeIfPresent(AnnotationColor.self, forKey: .middle)
        middleLocation = try container.decodeIfPresent(CGFloat.self, forKey: .middleLocation) ?? 0.5
        angleDegrees = try container.decodeIfPresent(CGFloat.self, forKey: .angleDegrees) ?? 90
    }
}

/// The curated fills the beautify panel offers (docs/09 U1.1).
///
/// Curated rather than a colour picker as the primary affordance: the whole promise of
/// beautify is that a screenshot comes out looking designed without the user making design
/// decisions. A picker asks them to make one. The picker is still there, second.
///
/// The wallpaper case takes a file path, and only ever a local one: bundled art or an image
/// the user imported. There is no pack, no catalogue and no download — CLAUDE.md rule 1
/// (zero network) is not negotiable for a decorative feature.
public enum BeautifyPalette {
    /// Sixteen flat fills, neutral through warm through cool.
    public static let solids: [AnnotationColor] = [
        "FFFFFF", "F5F5F7", "E8E8ED", "BDC0C7",
        "6B7080", "333640", "17171C", "000000",
        "FA6B5C", "FCA84A", "FAD65C", "78C978",
        "4AA8E3", "5A6BDE", "9966E3", "E878B8"
    ].map(AnnotationColor.init(hex:))

    /// Sixteen three-stop ramps. Each keeps a designed midpoint rather than passing through
    /// whatever sRGB interpolation produces.
    ///
    /// Written as hex triples because sixteen gradients read as a table of colours and not
    /// as a hundred and forty-four floating-point literals.
    public static let gradients: [BeautifyGradient] = [
        gradient("5C82FC", "8C6BFA", "BF66F2", 90),
        gradient("FC855C", "FA5C82", "BF4DB8", 120),
        gradient("33C7D9", "4099E6", "5A6BDE", 90),
        gradient("FCC95C", "FA8C59", "E14F70", 135),
        gradient("29B88C", "3399A8", "3D70BD", 90),
        gradient("F0F0F5", "D9E0F0", "B8CCEB", 90),
        gradient("17171F", "29233D", "423361", 90),
        gradient("FCE6CC", "FAC7B8", "F09EAD", 110),
        gradient("87DBC9", "66BDD9", "578FD6", 90),
        gradient("FCA84A", "FA7352", "9E3870", 135),
        gradient("29335C", "3D4D8C", "5775BF", 90),
        gradient("E6F29E", "9ED994", "52AD8F", 90),
        gradient("FA8CB8", "D973D1", "8C66E6", 120),
        gradient("3D3D42", "5C5961", "8C8A94", 90),
        gradient("FCF2E0", "F5DBBD", "E0B894", 100),
        gradient("246B70", "298C85", "4DB88C", 90)
    ]

    /// One ramp, from three hex triples and an angle.
    private static func gradient(
        _ start: String,
        _ middle: String,
        _ end: String,
        _ angle: CGFloat
    ) -> BeautifyGradient {
        BeautifyGradient(
            start: AnnotationColor(hex: start),
            middle: AnnotationColor(hex: middle),
            end: AnnotationColor(hex: end),
            angleDegrees: angle
        )
    }
}

extension AnnotationColor {
    /// A colour from a six-digit sRGB hex string, for tables of curated colours.
    ///
    /// Unparseable input is mid-grey rather than a crash: these are literals in this
    /// file, so a bad one is a typo to notice in review, not a reason to take the editor
    /// down at runtime.
    init(hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
