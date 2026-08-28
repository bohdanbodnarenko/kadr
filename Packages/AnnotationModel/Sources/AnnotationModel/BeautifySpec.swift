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
    /// A curated or custom ramp, with an optional designed midpoint (docs/09 U1.1).
    case gradient(BeautifyGradient)
    /// A local file path — bundled art or an image the user imported. Never a URL: there
    /// are no wallpaper packs to download, by rule (CLAUDE.md rule 1). The renderer falls
    /// back to a dark fill if the file is missing.
    case image(path: String)

    /// The two-stop spelling earlier documents used, kept as a constructor so call sites
    /// and presets read the same as before.
    public static func gradient(
        start: AnnotationColor,
        end: AnnotationColor,
        angleDegrees: CGFloat
    ) -> BeautifyBackdrop {
        .gradient(BeautifyGradient(start: start, end: end, angleDegrees: angleDegrees))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case solid, gradient, image
        /// The pre-U1.1 shape: a `gradient` object holding these three keys directly.
        case start, end, angleDegrees
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let colour = try container.decodeIfPresent(AnnotationColor.self, forKey: .solid) {
            self = .solid(colour)
        } else if let path = try container.decodeIfPresent(String.self, forKey: .image) {
            self = .image(path: path)
        } else if let ramp = try container.decodeIfPresent(BeautifyGradient.self, forKey: .gradient) {
            self = .gradient(ramp)
        } else if let start = try container.decodeIfPresent(AnnotationColor.self, forKey: .start) {
            // A document written before gradients were their own type.
            self = try .gradient(BeautifyGradient(
                start: start,
                end: container.decode(AnnotationColor.self, forKey: .end),
                angleDegrees: container.decodeIfPresent(CGFloat.self, forKey: .angleDegrees) ?? 90
            ))
        } else {
            self = .solid(.white)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .solid(colour): try container.encode(colour, forKey: .solid)
        case let .gradient(ramp): try container.encode(ramp, forKey: .gradient)
        case let .image(path): try container.encode(path, forKey: .image)
        }
    }
}

/// Drop shadow of the rounded capture card.
///
/// Blur and offset are normalized like every other beautify length, so a preset's shadow
/// stays proportionally the same on a phone-sized crop and a 5K capture (docs/09 U1.1).
public struct BeautifyShadow: Codable, Hashable, Sendable {
    public var opacity: CGFloat
    public var blur: BeautifyMetric
    public var offsetY: BeautifyMetric

    public init(
        opacity: CGFloat = 0,
        blur: BeautifyMetric = .relative(0.05),
        offsetY: BeautifyMetric = .relative(0.02)
    ) {
        self.opacity = min(max(opacity, 0), 1)
        self.blur = blur
        self.offsetY = offsetY
    }

    public static let none = BeautifyShadow(opacity: 0, blur: .zero, offsetY: .zero)
    public static let soft = BeautifyShadow(opacity: 0.28, blur: .relative(0.05), offsetY: .relative(0.022))

    public var isEnabled: Bool {
        opacity > 0 && !blur.isZero
    }

    /// Extra canvas inset so the shadow is not clipped at export.
    public func outset(shortestEdge: CGFloat) -> CGFloat {
        guard isEnabled else { return 0 }
        return blur.resolved(shortestEdge: shortestEdge)
            + abs(offsetY.resolved(shortestEdge: shortestEdge))
    }

    /// Documents written before U1.1 stored blur and offset as bare point values, which
    /// `BeautifyMetric` decodes as `.points` — so they open unchanged, just without the
    /// scaling. Nothing here needs a version bump.
    private enum CodingKeys: String, CodingKey {
        case opacity, blur, offsetY
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0
        blur = try container.decodeIfPresent(BeautifyMetric.self, forKey: .blur) ?? .zero
        offsetY = try container.decodeIfPresent(BeautifyMetric.self, forKey: .offsetY) ?? .zero
    }
}

/// Non-destructive canvas chrome: padding, backdrop, corners, shadow, aspect, alignment
/// (docs/03 §3 P2, docs/09 U1.1).
///
/// Stored as an `AnnotationCommand` so it undo/redoes with everything else and round-trips
/// in the `.kadr` file. It is not selectable on the canvas.
public struct BeautifySpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    /// Space around the capture, normalized to its shortest edge so a preset keeps its
    /// visual weight whatever it is applied to.
    public var padding: BeautifyMetric
    public var cornerRadius: BeautifyMetric
    public var backdrop: BeautifyBackdrop
    public var shadow: BeautifyShadow
    public var aspect: BeautifyAspect
    /// Where the capture sits in the canvas.
    public var alignment: BeautifyAlignment
    /// Whether a non-centre alignment presses the capture against the canvas edge —
    /// zero padding there, and the corners that touch it squared off.
    ///
    /// On by default because it is the reason to offer alignment at all: a screenshot that
    /// runs off the bottom of the frame is a composition, one merely pushed towards the
    /// bottom is a mistake.
    public var sticksToEdges: Bool

    public init(
        id: AnnotationID = AnnotationID(),
        padding: BeautifyMetric = .relative(0.08),
        cornerRadius: BeautifyMetric = .relative(0.03),
        backdrop: BeautifyBackdrop = .solid(.white),
        shadow: BeautifyShadow = .soft,
        aspect: BeautifyAspect = .original,
        alignment: BeautifyAlignment = .center,
        sticksToEdges: Bool = true
    ) {
        self.id = id
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.backdrop = backdrop
        self.shadow = shadow
        self.aspect = aspect
        self.alignment = alignment
        self.sticksToEdges = sticksToEdges
    }

    /// The edges this spec presses the capture against.
    public var stuckEdges: BeautifyEdges {
        sticksToEdges ? BeautifyEdges.stuck(by: alignment) : .none
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, padding, cornerRadius, backdrop, shadow, aspect, alignment, sticksToEdges
        /// Pre-U1.1: a bool that put aspect-ratio slack at the bottom instead of splitting
        /// it. That is what `.top` alignment means now, so it migrates rather than lingers.
        case autoBalance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(AnnotationID.self, forKey: .id) ?? AnnotationID()
        padding = try container.decodeIfPresent(BeautifyMetric.self, forKey: .padding) ?? .relative(0.08)
        cornerRadius = try container.decodeIfPresent(BeautifyMetric.self, forKey: .cornerRadius)
            ?? .relative(0.03)
        backdrop = try container.decodeIfPresent(BeautifyBackdrop.self, forKey: .backdrop) ?? .solid(.white)
        shadow = try container.decodeIfPresent(BeautifyShadow.self, forKey: .shadow) ?? .soft
        aspect = try container.decodeIfPresent(BeautifyAspect.self, forKey: .aspect) ?? .original

        if let alignment = try container.decodeIfPresent(BeautifyAlignment.self, forKey: .alignment) {
            self.alignment = alignment
            // Old documents have no alignment and never stuck to anything; new ones say so.
            sticksToEdges = try container.decodeIfPresent(Bool.self, forKey: .sticksToEdges) ?? true
        } else {
            let balanced = try container.decodeIfPresent(Bool.self, forKey: .autoBalance) ?? true
            alignment = balanced ? .center : .top
            // Sticking would move a document that predates it, so it stays off on decode.
            sticksToEdges = false
        }
    }

    /// Explicit because `CodingKeys` carries a migration-only key with no property behind
    /// it, and because `autoBalance` must not be written back out — a document Kadr saves
    /// says what it means now.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(backdrop, forKey: .backdrop)
        try container.encode(shadow, forKey: .shadow)
        try container.encode(aspect, forKey: .aspect)
        try container.encode(alignment, forKey: .alignment)
        try container.encode(sticksToEdges, forKey: .sticksToEdges)
    }

    // MARK: - Presets

    public static let cleanWhite = BeautifySpec()

    public static let twitter = BeautifySpec(
        padding: .relative(0.10),
        cornerRadius: .relative(0.035),
        backdrop: .gradient(BeautifyPalette.gradients[5]),
        shadow: .soft,
        aspect: .sixteenNine
    )

    public static let instagram = BeautifySpec(
        padding: .relative(0.12),
        cornerRadius: .relative(0.04),
        backdrop: .gradient(BeautifyPalette.gradients[7]),
        shadow: BeautifyShadow(opacity: 0.22, blur: .relative(0.06), offsetY: .relative(0.025)),
        aspect: .fourFive
    )

    public static let story = BeautifySpec(
        padding: .relative(0.08),
        cornerRadius: .relative(0.035),
        backdrop: .gradient(BeautifyPalette.gradients[6]),
        shadow: BeautifyShadow(opacity: 0.4, blur: .relative(0.045), offsetY: .relative(0.018)),
        aspect: .nineSixteen
    )

    /// The bleeds-off-the-bottom composition the alignment work exists for (docs/09 U1.1).
    public static let stuckBottom = BeautifySpec(
        padding: .relative(0.12),
        cornerRadius: .relative(0.035),
        backdrop: .gradient(BeautifyPalette.gradients[0]),
        shadow: .none,
        aspect: .sixteenNine,
        alignment: .bottom,
        sticksToEdges: true
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
        BeautifyPreset(id: "story", title: "Story", spec: .story),
        BeautifyPreset(id: "stuck", title: "Edge Bleed", spec: .stuckBottom)
    ]
}
