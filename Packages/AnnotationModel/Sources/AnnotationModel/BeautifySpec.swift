import CoreGraphics
import Foundation

/// How the export canvas is proportioned around the capture (docs/03 §3 P2).
public enum BeautifyAspect: String, Codable, CaseIterable, Sendable {
    /// Keep the capture's own proportions; only padding and shadow grow the canvas.
    case original
    case square
    case fourFive
    case sixteenNine
    case nineSixteen
    case fourThree

    /// Width over height, or `nil` when the capture keeps its own ratio.
    public var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .fourFive: 4 / 5
        case .sixteenNine: 16 / 9
        case .nineSixteen: 9 / 16
        case .fourThree: 4 / 3
        }
    }

    public var title: String {
        switch self {
        case .original: "Original"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        case .fourThree: "4:3"
        }
    }
}

/// The fill behind a beautified capture (docs/03 §3 P2).
public enum BeautifyBackdrop: Codable, Hashable, Sendable {
    case solid(AnnotationColor)
    /// `angleDegrees` is measured from the positive x-axis, clockwise in the model's
    /// top-left space, so 90 is top to bottom.
    case gradient(start: AnnotationColor, end: AnnotationColor, angleDegrees: CGFloat)
    /// A file path. The renderer falls back to a dark fill if the file is missing.
    case image(path: String)
}

/// Drop shadow of the rounded capture card.
public struct BeautifyShadow: Codable, Hashable, Sendable {
    public var opacity: CGFloat
    public var blur: CGFloat
    public var offsetY: CGFloat

    public init(opacity: CGFloat = 0, blur: CGFloat = 24, offsetY: CGFloat = 12) {
        self.opacity = min(max(opacity, 0), 1)
        self.blur = max(blur, 0)
        self.offsetY = offsetY
    }

    public static let none = BeautifyShadow(opacity: 0, blur: 0, offsetY: 0)
    public static let soft = BeautifyShadow(opacity: 0.28, blur: 28, offsetY: 12)

    public var isEnabled: Bool {
        opacity > 0 && blur > 0
    }

    /// Extra canvas inset so the shadow is not clipped at export.
    public var outset: CGFloat {
        guard isEnabled else { return 0 }
        return blur + abs(offsetY)
    }
}

/// Non-destructive canvas chrome: padding, backdrop, corners, shadow, aspect (docs/03 §3 P2).
///
/// Stored as an `AnnotationCommand` so it undo/redoes with everything else and round-trips
/// in the `.kadr` file. It is not selectable on the canvas.
public struct BeautifySpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var backdrop: BeautifyBackdrop
    public var shadow: BeautifyShadow
    public var aspect: BeautifyAspect
    /// When true, leftover space after padding and aspect is split equally so the capture
    /// sits in the middle. When false, extra space from an aspect preset sits at the bottom.
    public var autoBalance: Bool

    public init(
        id: AnnotationID = AnnotationID(),
        padding: CGFloat = 48,
        cornerRadius: CGFloat = 16,
        backdrop: BeautifyBackdrop = .solid(.white),
        shadow: BeautifyShadow = .soft,
        aspect: BeautifyAspect = .original,
        autoBalance: Bool = true
    ) {
        self.id = id
        self.padding = max(padding, 0)
        self.cornerRadius = max(cornerRadius, 0)
        self.backdrop = backdrop
        self.shadow = shadow
        self.aspect = aspect
        self.autoBalance = autoBalance
    }

    public static let cleanWhite = BeautifySpec()

    public static let twitter = BeautifySpec(
        padding: 64,
        cornerRadius: 20,
        backdrop: .gradient(
            start: AnnotationColor(red: 0.76, green: 0.86, blue: 0.98),
            end: AnnotationColor(red: 0.93, green: 0.96, blue: 1),
            angleDegrees: 90
        ),
        shadow: .soft,
        aspect: .sixteenNine,
        autoBalance: true
    )

    public static let instagram = BeautifySpec(
        padding: 72,
        cornerRadius: 24,
        backdrop: .gradient(
            start: AnnotationColor(red: 0.98, green: 0.82, blue: 0.70),
            end: AnnotationColor(red: 0.95, green: 0.55, blue: 0.72),
            angleDegrees: 135
        ),
        shadow: BeautifyShadow(opacity: 0.22, blur: 32, offsetY: 14),
        aspect: .fourFive,
        autoBalance: true
    )

    public static let story = BeautifySpec(
        padding: 48,
        cornerRadius: 20,
        backdrop: .gradient(
            start: AnnotationColor(red: 0.10, green: 0.10, blue: 0.14),
            end: AnnotationColor(red: 0.22, green: 0.18, blue: 0.32),
            angleDegrees: 90
        ),
        shadow: BeautifyShadow(opacity: 0.4, blur: 24, offsetY: 10),
        aspect: .nineSixteen,
        autoBalance: true
    )
}

/// A named starting point for the beautify inspector.
public struct BeautifyPreset: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var spec: BeautifySpec

    public init(id: String, title: String, spec: BeautifySpec) {
        self.id = id
        self.title = title
        self.spec = spec
    }

    public static let builtIn: [BeautifyPreset] = [
        BeautifyPreset(id: "clean", title: "Clean White", spec: .cleanWhite),
        BeautifyPreset(id: "twitter", title: "Twitter / X", spec: .twitter),
        BeautifyPreset(id: "instagram", title: "Instagram", spec: .instagram),
        BeautifyPreset(id: "story", title: "Story", spec: .story)
    ]
}

/// Where the capture sits inside a beautified canvas.
public struct BeautifyLayout: Equatable, Sendable {
    public var canvasSize: CGSize
    /// The capture's frame in canvas coordinates.
    public var contentRect: CGRect

    public init(canvasSize: CGSize, contentRect: CGRect) {
        self.canvasSize = canvasSize
        self.contentRect = contentRect
    }

    /// Lays the capture onto a canvas honouring padding, shadow, aspect and auto-balance.
    public static func compute(contentSize: CGSize, spec: BeautifySpec) -> BeautifyLayout {
        let width = max(contentSize.width, 1)
        let height = max(contentSize.height, 1)
        let inset = max(spec.padding, spec.shadow.outset)

        var canvasWidth = width + inset * 2
        var canvasHeight = height + inset * 2

        if let ratio = spec.aspect.ratio, ratio > 0 {
            let current = canvasWidth / canvasHeight
            if current < ratio {
                canvasWidth = canvasHeight * ratio
            } else if current > ratio {
                canvasHeight = canvasWidth / ratio
            }
        }

        let leftoverX = canvasWidth - width
        let leftoverY = canvasHeight - height
        let origin = if spec.autoBalance {
            CGPoint(x: leftoverX / 2, y: leftoverY / 2)
        } else {
            CGPoint(x: leftoverX / 2, y: inset)
        }

        return BeautifyLayout(
            canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
            contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height))
        )
    }
}
