import CoreGraphics
import Foundation

/// Remembers the last style used per tool (docs/03 §3).
///
/// Small but load-bearing: an annotation tool that forgets you set it to a thick blue
/// stroke every time you pick it up is exhausting to use.
public struct StyleMemory: Codable, Hashable, Sendable {
    private var strokes: [AnnotationTool: StrokeStyle]
    private var fills: [AnnotationTool: FillStyle]
    private var arrowHead: ArrowHead
    private var shapeKind: ShapeKind
    private var textStyle: TextStyle
    private var redactionStyle: RedactionStyle
    private var spotlightDimOpacity: CGFloat?
    private var spotlightCornerRadius: CGFloat?
    /// Optional on the wire, not in the API: a synthesized `Decodable` throws on a
    /// missing key for a non-optional property, so a memory encoded before this existed
    /// would fail to decode. Optional storage makes adding a remembered choice a
    /// non-breaking change.
    private var measuresBox: Bool?
    /// Last fill opacity, kept even when fill is off so toggling Filled back on restores
    /// the alpha the user picked rather than snapping to the default wash.
    private var fillOpacity: Double?
    private var counterNumbering: CounterNumbering?

    public init() {
        strokes = [:]
        fills = [:]
        arrowHead = .filled
        shapeKind = .rectangle
        textStyle = TextStyle()
        redactionStyle = .defaultBlur
    }

    public func stroke(for tool: AnnotationTool) -> StrokeStyle {
        strokes[tool] ?? Self.defaultStroke(for: tool)
    }

    public mutating func remember(_ stroke: StrokeStyle, for tool: AnnotationTool) {
        strokes[tool] = stroke
    }

    public func fill(for tool: AnnotationTool) -> FillStyle {
        fills[tool] ?? .none
    }

    public mutating func remember(_ fill: FillStyle, for tool: AnnotationTool) {
        fills[tool] = fill
        if let alpha = fill.color?.alpha {
            fillOpacity = alpha
        }
    }

    /// Fill alpha for the next filled shape. Survives turning Filled off, so the slider
    /// the user just dragged is still there when they turn it back on.
    public var lastFillOpacity: Double {
        get { fillOpacity ?? FillStyle.defaultAlpha }
        set { fillOpacity = min(max(newValue, 0), 1) }
    }

    public var lastArrowHead: ArrowHead {
        get { arrowHead }
        set { arrowHead = newValue }
    }

    public var lastShapeKind: ShapeKind {
        get { shapeKind }
        set { shapeKind = newValue }
    }

    public var lastTextStyle: TextStyle {
        get { textStyle }
        set { textStyle = newValue }
    }

    public var lastRedactionStyle: RedactionStyle {
        get { redactionStyle }
        set { redactionStyle = newValue }
    }

    public var lastSpotlightDimOpacity: CGFloat {
        get { spotlightDimOpacity ?? SpotlightSpec.defaultDimOpacity }
        set { spotlightDimOpacity = SpotlightSpec.clampedDim(newValue) }
    }

    public var lastSpotlightCornerRadius: CGFloat {
        get { spotlightCornerRadius ?? SpotlightSpec.defaultCornerRadius }
        set { spotlightCornerRadius = SpotlightSpec.clampedCorner(newValue) }
    }

    /// Whether the measure tool draws a box or a distance (docs/06 M21). Remembered like
    /// every other per-tool choice, so a session spent measuring boxes stays that way.
    /// Nil until the user picks one, so the default can change without rewriting anyone's
    /// stored memory (docs/08 §2.6).
    private var cropAspect: CropAspectPreset?

    public var lastMeasuresBox: Bool {
        get { measuresBox ?? false }
        set { measuresBox = newValue }
    }

    /// The ratio the crop tool is holding. Remembered like every other per-tool choice:
    /// somebody cropping a run of screenshots to 16:9 wants the next one to be 16:9 too.
    public var lastCropAspect: CropAspectPreset {
        get { cropAspect ?? .free }
        set { cropAspect = newValue }
    }

    public var lastCounterNumbering: CounterNumbering {
        get { counterNumbering ?? .arabic }
        set { counterNumbering = newValue }
    }

    /// Sensible starting points per tool, so the first use of each is already usable.
    static func defaultStroke(for tool: AnnotationTool) -> StrokeStyle {
        switch tool {
        case .highlighter: StrokeStyle(color: .highlighterYellow, width: 20)
        case .freehand: StrokeStyle(width: 3)
        // A measurement is a thin line whose job is to be precise, not loud.
        case .measure: StrokeStyle(color: .annotationRed, width: 2)
        case .counter, .text, .redaction, .spotlight, .crop, .beautify, .camera, .progressiveBlur,
             .watermark, .subjectLift, .image: StrokeStyle()
        case .arrow, .shape, .line: StrokeStyle()
        }
    }
}

/// `AnnotationTool` keys encode as their raw strings, so the stored memory stays
/// readable and survives a tool being added.
extension AnnotationTool: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        StringCodingKey(stringValue: rawValue)
    }

    public init?(codingKey: some CodingKey) {
        self.init(rawValue: codingKey.stringValue)
    }
}

private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
