import CoreGraphics
import Foundation

/// A stable identity for one annotation.
public struct AnnotationID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// An sRGB colour, stored as components rather than a platform colour type.
///
/// The model must not import AppKit (docs/04 §2), and a serialised colour has to mean
/// the same thing on any machine that opens the `.kadr` file — so components it is.
public struct AnnotationColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    /// The default annotation colour (docs/03 §3: "smart default color (auto red)").
    public static let annotationRed = AnnotationColor(red: 1, green: 0.23, blue: 0.19)
    public static let highlighterYellow = AnnotationColor(red: 1, green: 0.92, blue: 0.23, alpha: 0.4)
    public static let white = AnnotationColor(red: 1, green: 1, blue: 1)
    public static let black = AnnotationColor(red: 0, green: 0, blue: 0)

    /// The strip the inspector offers, so a colour is one click rather than a picker hunt.
    public static let annotationSwatches: [AnnotationColor] = [
        .annotationRed,
        AnnotationColor(red: 1, green: 0.55, blue: 0.14),
        AnnotationColor(red: 1, green: 0.84, blue: 0.04),
        AnnotationColor(red: 0.22, green: 0.78, blue: 0.35),
        AnnotationColor(red: 0.13, green: 0.59, blue: 0.95),
        AnnotationColor(red: 0.45, green: 0.37, blue: 0.95),
        AnnotationColor(red: 0.93, green: 0.32, blue: 0.62),
        .white,
        .black
    ]

    public func withAlpha(_ alpha: Double) -> AnnotationColor {
        AnnotationColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Rec. 601 luma, used to pick contrasting text over a filled shape.
    public var luminance: Double {
        0.299 * red + 0.587 * green + 0.114 * blue
    }
}

/// How an annotation's outline is drawn.
public struct StrokeStyle: Codable, Hashable, Sendable {
    public var color: AnnotationColor
    public var width: CGFloat
    /// Dash pattern in points; empty means a solid line.
    public var dashPattern: [CGFloat]

    public init(color: AnnotationColor = .annotationRed, width: CGFloat = 4, dashPattern: [CGFloat] = []) {
        self.color = color
        self.width = max(width, 0)
        self.dashPattern = dashPattern
    }

    /// The stroke width presets from docs/03 §3.
    public static let widthPresets: [CGFloat] = [2, 4, 6, 10, 16]

    /// The inspector slider's range. Presets sit inside it; the highlighter's default
    /// (20 pt) has to as well, or the first use of that tool would clamp.
    public static let widthRange: ClosedRange<CGFloat> = 1 ... 32
}

/// How an annotation's interior is filled.
public struct FillStyle: Codable, Hashable, Sendable {
    /// `nil` means no fill, which is the default for shapes (docs/03 §3).
    public var color: AnnotationColor?

    public init(color: AnnotationColor? = nil) {
        self.color = color
    }

    public static let none = FillStyle()

    /// The fill alpha used when Filled is first turned on, before the user picks one.
    public static let defaultAlpha: Double = 0.25
}

/// Arrow head shapes (docs/03 §3: three head styles).
public enum ArrowHead: String, Codable, CaseIterable, Sendable {
    /// A solid triangle.
    case filled
    /// Two lines, like a hand-drawn arrow.
    case open
    /// A triangle with a notched back edge.
    case concave

    public var title: String {
        switch self {
        case .filled: "Filled"
        case .open: "Open"
        case .concave: "Concave"
        }
    }
}

/// Rect-based shapes (docs/03 §3). Lines are their own command because a line has a
/// direction and a rect does not.
public enum ShapeKind: Codable, Hashable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: CGFloat)
    case ellipse

    /// The three choices the inspector shows. Rounded keeps a default radius so picking
    /// the family does not also ask for a corner size.
    public enum Family: String, CaseIterable, Identifiable, Sendable {
        case rectangle
        case rounded
        case ellipse

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .rectangle: "Rectangle"
            case .rounded: "Rounded"
            case .ellipse: "Ellipse"
            }
        }

        public var symbolName: String {
            switch self {
            case .rectangle: "rectangle"
            case .rounded: "rounded.rectangle"
            case .ellipse: "oval"
            }
        }

        public var kind: ShapeKind {
            switch self {
            case .rectangle: .rectangle
            case .rounded: .roundedRectangle(cornerRadius: 12)
            case .ellipse: .ellipse
            }
        }

        public init(_ kind: ShapeKind) {
            switch kind {
            case .rectangle: self = .rectangle
            case .roundedRectangle: self = .rounded
            case .ellipse: self = .ellipse
            }
        }
    }
}

/// How a region is obscured (docs/03 §3).
public enum RedactionKind: String, CaseIterable, Hashable, Sendable {
    case blur
    case pixelate
    case erase

    public var title: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .erase: "Erase"
        }
    }
}

/// How a region is obscured (docs/03 §3).
public enum RedactionStyle: Codable, Hashable, Sendable {
    case blur(radius: CGFloat)
    /// Pixelation uses randomised per-cell displacement, because a predictable grid can
    /// be attacked — an even mosaic over known glyph shapes is recoverable.
    case pixelate(cellSize: CGFloat)
    /// Fill with the colour sampled from the region's edge, so UI chrome disappears.
    case erase

    /// Screendrop's default strength (0.55): enough to hide text, not a wall of fog.
    public static let defaultBlur = RedactionStyle.blur(density: 0.55)
    public static let defaultPixelate = RedactionStyle.pixelate(density: 0.55)
    public static let defaultErase = RedactionStyle.erase

    public var kind: RedactionKind {
        switch self {
        case .blur: .blur
        case .pixelate: .pixelate
        case .erase: .erase
        }
    }

    /// Strength on Screendrop's 0...1 slider. Blur radius is `2 + density × 28`;
    /// pixel block size is `4 + density × 36`. Erase has no strength.
    public var density: CGFloat {
        switch self {
        case let .blur(radius):
            min(max((radius - 2) / 28, 0), 1)
        case let .pixelate(cellSize):
            min(max((cellSize - 4) / 36, 0), 1)
        case .erase:
            0.55
        }
    }

    public static func blur(density: CGFloat) -> RedactionStyle {
        .blur(radius: 2 + clampedDensity(density) * 28)
    }

    public static func pixelate(density: CGFloat) -> RedactionStyle {
        .pixelate(cellSize: 4 + clampedDensity(density) * 36)
    }

    public func withKind(_ kind: RedactionKind) -> RedactionStyle {
        switch kind {
        case .blur: .blur(density: density)
        case .pixelate: .pixelate(density: density)
        case .erase: .erase
        }
    }

    /// Keeps Blur vs Pixelate while the Strength slider moves.
    public func withDensity(_ density: CGFloat) -> RedactionStyle {
        switch kind {
        case .pixelate: .pixelate(density: density)
        case .blur: .blur(density: density)
        case .erase: .erase
        }
    }

    private static func clampedDensity(_ density: CGFloat) -> CGFloat {
        min(max(density, 0), 1)
    }
}

/// One of the text presets from docs/03 §3, or a custom style.
public struct TextStyle: Codable, Hashable, Sendable {
    public var fontName: String
    public var fontSize: CGFloat
    public var isBold: Bool
    public var color: AnnotationColor
    /// A filled pill behind the text; `nil` for plain text.
    public var backgroundColor: AnnotationColor?

    public init(
        fontName: String = "Helvetica Neue",
        fontSize: CGFloat = 24,
        isBold: Bool = true,
        color: AnnotationColor = .annotationRed,
        backgroundColor: AnnotationColor? = nil
    ) {
        self.fontName = fontName
        self.fontSize = max(fontSize, 1)
        self.isBold = isBold
        self.color = color
        self.backgroundColor = backgroundColor
    }

    /// The inspector presets (docs/03 §3, CleanShot §8.2).
    public static let presets: [(name: String, style: TextStyle)] = [
        ("Callout", TextStyle()),
        ("Heading", TextStyle(fontSize: 40, color: .black)),
        ("Body", TextStyle(fontSize: 18, isBold: false, color: .black)),
        ("Badge", TextStyle(fontSize: 20, color: .white, backgroundColor: .annotationRed)),
        ("Caption", TextStyle(fontSize: 14, isBold: false, color: .white, backgroundColor: .black)),
        ("Highlight", TextStyle(
            fontSize: 22,
            isBold: false,
            color: .black,
            backgroundColor: AnnotationColor(red: 1, green: 0.92, blue: 0.23)
        )),
        ("Code", TextStyle(
            fontName: "Menlo",
            fontSize: 16,
            isBold: false,
            color: .black,
            backgroundColor: AnnotationColor(red: 0.94, green: 0.94, blue: 0.94)
        ))
    ]
}

/// How a counter badge writes its number (docs/03 §3).
public enum CounterNumbering: String, Codable, Hashable, Sendable, CaseIterable {
    case arabic
    case roman
    case latinUpper
    case latinLower

    public var title: String {
        switch self {
        case .arabic: "1, 2, 3"
        case .roman: "I, II, III"
        case .latinUpper: "A, B, C"
        case .latinLower: "a, b, c"
        }
    }

    /// The glyph drawn inside the badge for `number` (1-based).
    public func label(for number: Int) -> String {
        let value = max(number, 1)
        switch self {
        case .arabic: return "\(value)"
        case .roman: return Self.roman(value)
        case .latinUpper: return Self.latin(value).uppercased()
        case .latinLower: return Self.latin(value)
        }
    }

    private static func roman(_ number: Int) -> String {
        let glyphs: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var remaining = min(number, 3999)
        var result = ""
        for (value, glyph) in glyphs {
            while remaining >= value {
                result += glyph
                remaining -= value
            }
        }
        return result
    }

    private static func latin(_ number: Int) -> String {
        var value = number
        var letters: [Character] = []
        while value > 0 {
            value -= 1
            let code = 97 + (value % 26)
            if let scalar = UnicodeScalar(code) {
                letters.append(Character(scalar))
            }
            value /= 26
        }
        return String(letters.reversed())
    }
}
