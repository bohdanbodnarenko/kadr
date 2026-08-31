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
}

/// How an annotation's interior is filled.
public struct FillStyle: Codable, Hashable, Sendable {
    /// `nil` means no fill, which is the default for shapes (docs/03 §3).
    public var color: AnnotationColor?

    public init(color: AnnotationColor? = nil) {
        self.color = color
    }

    public static let none = FillStyle()
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
public enum RedactionStyle: Codable, Hashable, Sendable {
    case blur(radius: CGFloat)
    /// Pixelation uses randomised per-cell displacement, because a predictable grid can
    /// be attacked — an even mosaic over known glyph shapes is recoverable.
    case pixelate(cellSize: CGFloat)

    public static let defaultBlur = RedactionStyle.blur(radius: 12)
    public static let defaultPixelate = RedactionStyle.pixelate(cellSize: 12)
}

/// One of the five text presets from docs/03 §3, or a custom style.
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

    /// The five presets the inspector offers (docs/03 §3).
    public static let presets: [(name: String, style: TextStyle)] = [
        ("Callout", TextStyle()),
        ("Heading", TextStyle(fontSize: 40, color: .black)),
        ("Body", TextStyle(fontSize: 18, isBold: false, color: .black)),
        ("Badge", TextStyle(fontSize: 20, color: .white, backgroundColor: .annotationRed)),
        ("Caption", TextStyle(fontSize: 14, isBold: false, color: .white, backgroundColor: .black))
    ]
}
