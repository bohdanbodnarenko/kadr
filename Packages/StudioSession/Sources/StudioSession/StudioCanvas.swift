import CoreGraphics
import Foundation

/// A colour in the studio canvas, 0…1 linear-ish sRGB (docs/09 U3.5).
public struct StudioColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Default solid fill when somebody first turns a background on.
    public static let graphite = StudioColor(red: 0.22, green: 0.23, blue: 0.25)
    /// Default click ripple — a white ring on the scene, the way a live overlay draws one.
    public static let white = StudioColor(red: 1, green: 1, blue: 1)
}

/// The fill behind a padded recording card.
public enum StudioBackdrop: Sendable, Hashable, Codable {
    case none
    case solid(StudioColor)
    case gradient(StudioColor, StudioColor)
    /// An image copied into the session, aspect-filled behind the card.
    case wallpaper

    public var kind: StudioBackdropKind {
        switch self {
        case .none:
            .none
        case .solid:
            .colour
        case .gradient:
            .gradient
        case .wallpaper:
            .wallpaper
        }
    }
}

/// How the area around the recording is filled (docs/09 U3.5).
public enum StudioBackdropKind: String, Sendable, CaseIterable, Identifiable {
    case none
    case colour
    case gradient
    case wallpaper

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .none:
            "None"
        case .colour:
            "Colour"
        case .gradient:
            "Gradient"
        case .wallpaper:
            "Wallpaper"
        }
    }
}

/// Padding, corners, shadow and backdrop around the recording (docs/09 U3.5).
///
/// Default is a full-bleed frame so an old project, and a fresh "as recorded" edit, do not
/// grow a border nobody asked for. The Presenter look — a rounded card on a gradient — is
/// a preset, not the identity.
public struct StudioCanvas: Sendable, Hashable, Codable {
    /// Inset around the card, as a fraction of the card's shortest edge.
    public var paddingFraction: Double
    /// Card corner radius, likewise normalized.
    public var cornerRadiusFraction: Double
    /// Drop-shadow strength, 0…1.
    public var shadow: Double
    public var background: StudioBackdrop
    /// File name, inside the session folder, of an imported wallpaper. Nil means none.
    public var wallpaperFileName: String?

    public init(
        paddingFraction: Double = 0,
        cornerRadiusFraction: Double = 0,
        shadow: Double = 0,
        background: StudioBackdrop = .none,
        wallpaperFileName: String? = nil
    ) {
        self.paddingFraction = min(max(paddingFraction, 0), Self.maximumPadding)
        self.cornerRadiusFraction = min(max(cornerRadiusFraction, 0), Self.maximumCornerRadius)
        self.shadow = min(max(shadow, 0), 1)
        self.background = background
        self.wallpaperFileName = wallpaperFileName
    }

    public static let maximumPadding: Double = 0.2
    public static let maximumCornerRadius: Double = 0.12
    public static let identity = StudioCanvas()

    /// Rounded card on a dark gradient — the Screen-Studio look.
    public static let presenter = StudioCanvas(
        paddingFraction: 0.06,
        cornerRadiusFraction: 0.022,
        shadow: 0.45,
        background: .gradient(
            StudioColor(red: 0.07, green: 0.09, blue: 0.16),
            StudioColor(red: 0.16, green: 0.12, blue: 0.28)
        )
    )

    public static let paper = StudioCanvas(
        paddingFraction: 0.07,
        cornerRadiusFraction: 0.018,
        shadow: 0.28,
        background: .solid(StudioColor(red: 0.93, green: 0.93, blue: 0.91))
    )

    /// True when the canvas adds no pixels and no clip around the recording.
    public var isIdentity: Bool {
        paddingFraction < 0.0005
            && cornerRadiusFraction < 0.0005
            && shadow < 0.0005
            && background == .none
    }

    /// Switches the fill. A colour on a full-bleed frame would be invisible, so the card
    /// opens to the Presenter inset if it currently covers the whole output.
    public mutating func setBackdropKind(_ kind: StudioBackdropKind) {
        switch kind {
        case .none:
            background = .none
        case .colour:
            revealCardIfNeeded()
            if case .solid = background {
                return
            }
            background = .solid(.graphite)
        case .gradient:
            revealCardIfNeeded()
            if case .gradient = background {
                return
            }
            background = Self.presenter.background
        case .wallpaper:
            revealCardIfNeeded()
            background = .wallpaper
        }
    }

    public mutating func setSolid(_ color: StudioColor) {
        revealCardIfNeeded()
        background = .solid(color)
    }

    public mutating func setGradient(from start: StudioColor, to end: StudioColor) {
        revealCardIfNeeded()
        background = .gradient(start, end)
    }

    private mutating func revealCardIfNeeded() {
        guard paddingFraction < 0.01 else { return }
        paddingFraction = Self.presenter.paddingFraction
        if cornerRadiusFraction < 0.001 {
            cornerRadiusFraction = Self.presenter.cornerRadiusFraction
        }
    }

    /// Where the card sits inside the exported frame.
    public func layout(cardSize: CGSize) -> StudioCanvasLayout {
        let card = CGSize(width: max(cardSize.width, 1), height: max(cardSize.height, 1))
        let shortest = min(card.width, card.height)
        let padding = shortest * paddingFraction
        let shadowRoom = shortest * shadow * 0.08
        let inset = max(padding, shadowRoom)
        let radius = shortest * cornerRadiusFraction
        if inset < 0.5 {
            return StudioCanvasLayout(
                canvasSize: card,
                cardRect: CGRect(origin: .zero, size: card),
                cornerRadius: radius
            )
        }
        return StudioCanvasLayout(
            canvasSize: CGSize(width: card.width + inset * 2, height: card.height + inset * 2),
            cardRect: CGRect(x: inset, y: inset, width: card.width, height: card.height),
            cornerRadius: radius
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paddingFraction, cornerRadiusFraction, shadow, background, wallpaperFileName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            paddingFraction: container.decodeIfPresent(Double.self, forKey: .paddingFraction) ?? 0,
            cornerRadiusFraction: container.decodeIfPresent(Double.self, forKey: .cornerRadiusFraction) ?? 0,
            shadow: container.decodeIfPresent(Double.self, forKey: .shadow) ?? 0,
            background: container.decodeIfPresent(StudioBackdrop.self, forKey: .background) ?? .none,
            wallpaperFileName: container.decodeIfPresent(String.self, forKey: .wallpaperFileName)
        )
    }
}

/// Canvas geometry in top-left pixels, shared by the preview and the export.
public struct StudioCanvasLayout: Sendable, Hashable {
    public var canvasSize: CGSize
    public var cardRect: CGRect
    public var cornerRadius: CGFloat

    public init(canvasSize: CGSize, cardRect: CGRect, cornerRadius: CGFloat) {
        self.canvasSize = canvasSize
        self.cardRect = cardRect
        self.cornerRadius = cornerRadius
    }
}
