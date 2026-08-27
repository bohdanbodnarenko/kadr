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

    /// Sensible starting points per tool, so the first use of each is already usable.
    static func defaultStroke(for tool: AnnotationTool) -> StrokeStyle {
        switch tool {
        case .highlighter: StrokeStyle(color: .highlighterYellow, width: 20)
        case .freehand: StrokeStyle(width: 3)
        case .counter, .text, .redaction, .crop: StrokeStyle()
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
