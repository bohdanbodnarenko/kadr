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

    /// Halfway to another colour, per channel.
    public func blended(with other: StudioColor, amount: Double = 0.5) -> StudioColor {
        let ratio = min(max(amount, 0), 1)
        return StudioColor(
            red: red + (other.red - red) * ratio,
            green: green + (other.green - green) * ratio,
            blue: blue + (other.blue - blue) * ratio
        )
    }

    /// Default solid fill when somebody first turns a background on.
    public static let graphite = StudioColor(red: 0.22, green: 0.23, blue: 0.25)
    /// Default click ripple — a white ring on the scene, the way a live overlay draws one.
    public static let white = StudioColor(red: 1, green: 1, blue: 1)
}

/// A multi-stop studio canvas ramp (docs/16 STU-C7).
///
/// Older sessions stored two colours as associated values `_0`/`_1`. Those decode here as
/// a vertical two-stop ramp so a Presenter look from an earlier Kadr still opens.
public struct StudioGradient: Sendable, Hashable, Codable {
    public var stops: [StudioColor]
    /// Degrees from the positive x-axis, matching beautify: 90 is top to bottom.
    public var angleDegrees: Double

    public init(stops: [StudioColor], angleDegrees: Double = 90) {
        if stops.count >= 2 {
            self.stops = stops
        } else if let only = stops.first {
            self.stops = [only, only]
        } else {
            self.stops = [.graphite, StudioColor(red: 0.07, green: 0.09, blue: 0.16)]
        }
        self.angleDegrees = angleDegrees
    }

    public init(from start: StudioColor, to end: StudioColor, angleDegrees: Double = 90) {
        self.init(stops: [start, end], angleDegrees: angleDegrees)
    }

    public var start: StudioColor {
        stops[0]
    }

    public var end: StudioColor {
        stops[stops.count - 1]
    }

    /// Adds a stop halfway between the ends, or drops the ones already there.
    ///
    /// The midpoint starts at the colour the ramp already shows at its middle, so adding one
    /// changes nothing until it is dragged — an edit that redraws the picture the moment it
    /// is offered is an edit nobody trusts.
    public func togglingMidpoint() -> StudioGradient {
        var next = self
        if stops.count > 2 {
            next.stops = [start, end]
        } else {
            next.stops = [start, start.blended(with: end), end]
        }
        return next
    }

    private enum CodingKeys: String, CodingKey {
        case stops, angleDegrees
        case start = "_0"
        case end = "_1"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stops = try container.decodeIfPresent([StudioColor].self, forKey: .stops), stops.count >= 2 {
            try self.init(
                stops: stops,
                angleDegrees: container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 90
            )
            return
        }
        let start = try container.decodeIfPresent(StudioColor.self, forKey: .start) ?? .graphite
        let end = try container.decodeIfPresent(StudioColor.self, forKey: .end)
            ?? StudioColor(red: 0.16, green: 0.12, blue: 0.28)
        self.init(from: start, to: end)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
        try container.encode(angleDegrees, forKey: .angleDegrees)
    }
}

/// The fill behind a padded recording card.
public enum StudioBackdrop: Sendable, Hashable, Codable {
    case none
    case solid(StudioColor)
    case gradient(StudioGradient)
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

    private enum CodingKeys: String, CodingKey {
        case none, solid, gradient, wallpaper
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.none) {
            self = .none
        } else if let colour = try container.decodeIfPresent(StudioColor.self, forKey: .solid) {
            self = .solid(colour)
        } else if container.contains(.wallpaper) {
            self = .wallpaper
        } else if let ramp = try container.decodeIfPresent(StudioGradient.self, forKey: .gradient) {
            self = .gradient(ramp)
        } else {
            self = .none
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encodeNil(forKey: .none)
        case let .solid(colour):
            try container.encode(colour, forKey: .solid)
        case let .gradient(ramp):
            try container.encode(ramp, forKey: .gradient)
        case .wallpaper:
            try container.encodeNil(forKey: .wallpaper)
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
            String(localized: "None", bundle: .module)
        case .colour:
            String(localized: "Color", bundle: .module)
        case .gradient:
            String(localized: "Gradient", bundle: .module)
        case .wallpaper:
            String(localized: "Wallpaper", bundle: .module)
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
        background: .gradient(StudioGradient(
            from: StudioColor(red: 0.07, green: 0.09, blue: 0.16),
            to: StudioColor(red: 0.16, green: 0.12, blue: 0.28)
        ))
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
        setGradient(StudioGradient(from: start, to: end, angleDegrees: currentGradientAngle))
    }

    public mutating func setGradient(_ ramp: StudioGradient) {
        revealCardIfNeeded()
        background = .gradient(ramp)
    }

    private var currentGradientAngle: Double {
        if case let .gradient(ramp) = background {
            return ramp.angleDegrees
        }
        return 90
    }

    private mutating func revealCardIfNeeded() {
        guard paddingFraction < 0.01 else { return }
        paddingFraction = Self.presenter.paddingFraction
        if cornerRadiusFraction < 0.001 {
            cornerRadiusFraction = Self.presenter.cornerRadiusFraction
        }
    }

    /// Where the card sits inside the exported frame.
    ///
    /// The canvas stays at the reframe output so padding cannot change the aspect ratio
    /// (docs/16 STU-A6). The card is scaled down, aspect-preserved, and centred.
    public func layout(cardSize: CGSize) -> StudioCanvasLayout {
        layout(canvasSize: cardSize, contentAspect: cardSize.width / max(cardSize.height, 1))
    }

    public func layout(canvasSize: CGSize, contentAspect: CGFloat) -> StudioCanvasLayout {
        let canvas = CGSize(width: max(canvasSize.width, 1), height: max(canvasSize.height, 1))
        let shortest = min(canvas.width, canvas.height)
        let pad = max(shortest * paddingFraction, shortest * shadow * 0.08)
        let radius = shortest * cornerRadiusFraction
        if pad < 0.5 {
            return StudioCanvasLayout(
                canvasSize: canvas,
                cardRect: CGRect(origin: .zero, size: canvas),
                cornerRadius: radius
            )
        }
        let available = CGSize(
            width: max(canvas.width - pad * 2, 1),
            height: max(canvas.height - pad * 2, 1)
        )
        let aspect = contentAspect > 0.0001 ? contentAspect : canvas.width / canvas.height
        let fitted = if available.width / available.height > aspect {
            CGSize(width: available.height * aspect, height: available.height)
        } else {
            CGSize(width: available.width, height: available.width / aspect)
        }
        return StudioCanvasLayout(
            canvasSize: canvas,
            cardRect: CGRect(
                x: (canvas.width - fitted.width) / 2,
                y: (canvas.height - fitted.height) / 2,
                width: fitted.width,
                height: fitted.height
            ),
            cornerRadius: min(radius, min(fitted.width, fitted.height) / 2)
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
