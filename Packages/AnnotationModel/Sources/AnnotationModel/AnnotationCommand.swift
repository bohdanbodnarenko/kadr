import CoreGraphics
import Foundation

/// An arrow, straight or curved (docs/03 §3).
public struct ArrowSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var start: CGPoint
    public var end: CGPoint
    /// Dragging the midpoint bends the arrow; `nil` is a straight one.
    public var controlPoint: CGPoint?
    public var head: ArrowHead
    public var stroke: StrokeStyle

    public init(
        id: AnnotationID = AnnotationID(),
        start: CGPoint,
        end: CGPoint,
        controlPoint: CGPoint? = nil,
        head: ArrowHead = .filled,
        stroke: StrokeStyle = StrokeStyle()
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.controlPoint = controlPoint
        self.head = head
        self.stroke = stroke
    }

    public var isCurved: Bool {
        controlPoint != nil
    }
}

/// A rectangle, rounded rectangle or ellipse.
public struct ShapeSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var kind: ShapeKind
    public var rect: CGRect
    public var stroke: StrokeStyle
    public var fill: FillStyle

    public init(
        id: AnnotationID = AnnotationID(),
        kind: ShapeKind = .rectangle,
        rect: CGRect,
        stroke: StrokeStyle = StrokeStyle(),
        fill: FillStyle = .none
    ) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.stroke = stroke
        self.fill = fill
    }
}

/// A straight line. Separate from `ShapeSpec` because a line has a direction and a
/// rectangle does not — storing one as a rect loses which way it was drawn.
public struct LineSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var start: CGPoint
    public var end: CGPoint
    public var stroke: StrokeStyle

    public init(
        id: AnnotationID = AnnotationID(),
        start: CGPoint,
        end: CGPoint,
        stroke: StrokeStyle = StrokeStyle()
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.stroke = stroke
    }
}

/// A freehand pencil stroke (docs/03 §3).
public struct FreehandSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    /// The raw sampled points. Smoothing happens at render time so the original input is
    /// never lost and the smoothing can improve without re-editing old documents.
    public var points: [CGPoint]
    public var isSmoothed: Bool
    public var stroke: StrokeStyle

    public init(
        id: AnnotationID = AnnotationID(),
        points: [CGPoint],
        isSmoothed: Bool = true,
        stroke: StrokeStyle = StrokeStyle()
    ) {
        self.id = id
        self.points = points
        self.isSmoothed = isSmoothed
        self.stroke = stroke
    }
}

/// A highlighter stroke, drawn with a multiply blend (docs/03 §3).
public struct HighlighterSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var points: [CGPoint]
    public var stroke: StrokeStyle

    public init(
        id: AnnotationID = AnnotationID(),
        points: [CGPoint],
        stroke: StrokeStyle = StrokeStyle(color: .highlighterYellow, width: 20)
    ) {
        self.id = id
        self.points = points
        self.stroke = stroke
    }
}

/// A text annotation (docs/03 §3).
public struct TextSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var string: String
    /// The laid-out frame. Width drives wrapping; height grows with the text.
    public var rect: CGRect
    public var style: TextStyle

    public init(
        id: AnnotationID = AnnotationID(),
        string: String = "",
        rect: CGRect,
        style: TextStyle = TextStyle()
    ) {
        self.id = id
        self.string = string
        self.rect = rect
        self.style = style
    }
}

/// A blurred or pixelated region (docs/03 §3).
public struct RedactionSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var rect: CGRect
    public var style: RedactionStyle

    public init(
        id: AnnotationID = AnnotationID(),
        rect: CGRect,
        style: RedactionStyle = .defaultBlur
    ) {
        self.id = id
        self.rect = rect
        self.style = style
    }
}

/// A numbered counter badge (docs/03 §3).
///
/// The number is stored rather than derived, so a document round-trips exactly; the
/// document renumbers them whenever the z-order changes.
public struct CounterSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var number: Int
    public var center: CGPoint
    public var radius: CGFloat
    public var fill: AnnotationColor
    public var textColor: AnnotationColor

    public init(
        id: AnnotationID = AnnotationID(),
        number: Int = 1,
        center: CGPoint,
        radius: CGFloat = 18,
        fill: AnnotationColor = .annotationRed,
        textColor: AnnotationColor = .white
    ) {
        self.id = id
        self.number = number
        self.center = center
        self.radius = max(radius, 1)
        self.fill = fill
        self.textColor = textColor
    }
}

/// A measurement drawn on the capture (docs/03 §3 P3, docs/06 M21).
///
/// The pixel ruler a designer or developer actually wants: drag across two edges and read
/// the distance, or drag a box and read its size. Both numbers are reported in points
/// *and* pixels on a Retina capture, because the two differ by a factor of two and only
/// one of them is the one being argued about in the code review.
public struct MeasureSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var start: CGPoint
    public var end: CGPoint
    /// Measure the box the drag describes rather than the distance across it.
    public var measuresBox: Bool
    public var stroke: StrokeStyle
    public var labelStyle: TextStyle

    public init(
        id: AnnotationID = AnnotationID(),
        start: CGPoint,
        end: CGPoint,
        measuresBox: Bool = false,
        stroke: StrokeStyle = StrokeStyle(color: .annotationRed, width: 2),
        labelStyle: TextStyle = TextStyle(fontSize: 13, color: .white, backgroundColor: .annotationRed)
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.measuresBox = measuresBox
        self.stroke = stroke
        self.labelStyle = labelStyle
    }

    /// The box the drag describes, in base-image points.
    public var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Point-to-point distance, in base-image points.
    public var length: CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    /// Whether the drag is close enough to one axis to be read as a straight measurement.
    ///
    /// Most measurements are horizontal or vertical — the width of a gutter, the height
    /// of a row — and a distance line that renders at 0.4° off true looks like a mistake.
    public var isAxisAligned: Bool {
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        return min(dx, dy) <= max(dx, dy) * 0.02
    }

    /// The label, in points and — when the capture is Retina — pixels.
    ///
    /// - Parameter scale: the base image's pixels per point.
    public func readout(scale: CGFloat) -> String {
        measuresBox
            ? Self.text(width: rect.width, height: rect.height, scale: scale)
            : Self.text(length: length, scale: scale)
    }

    static func text(length: CGFloat, scale: CGFloat) -> String {
        let points = Int(length.rounded())
        guard scale != 1 else { return "\(points) px" }
        return "\(points) pt · \(Int((length * scale).rounded())) px"
    }

    static func text(width: CGFloat, height: CGFloat, scale: CGFloat) -> String {
        let pointWidth = Int(width.rounded())
        let pointHeight = Int(height.rounded())
        guard scale != 1 else { return "\(pointWidth) × \(pointHeight) px" }
        let pixelWidth = Int((width * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())
        return "\(pointWidth) × \(pointHeight) pt · \(pixelWidth) × \(pixelHeight) px"
    }
}

/// A non-destructive crop (docs/03 §3).
public struct CropSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    /// The visible area, in base-image points. May extend beyond the image when the
    /// canvas is being expanded for padding.
    public var rect: CGRect
    public var canExpandCanvas: Bool

    public init(id: AnnotationID = AnnotationID(), rect: CGRect, canExpandCanvas: Bool = false) {
        self.id = id
        self.rect = rect
        self.canExpandCanvas = canExpandCanvas
    }
}

/// One annotation (docs/04 §6).
///
/// A `Codable` enum rather than a class hierarchy: annotations are values, the document
/// is an ordered list of them, and undo is a matter of keeping old lists around.
public enum AnnotationCommand: Codable, Hashable, Sendable, Identifiable {
    case arrow(ArrowSpec)
    case shape(ShapeSpec)
    case line(LineSpec)
    case freehand(FreehandSpec)
    case highlighter(HighlighterSpec)
    case text(TextSpec)
    case redaction(RedactionSpec)
    case counter(CounterSpec)
    case crop(CropSpec)
    case beautify(BeautifySpec)
    case camera(AnnotationCameraSpec)
    case progressiveBlur(ProgressiveBlurSpec)
    case measure(MeasureSpec)
    case subjectLift(SubjectLiftSpec)
    case image(ImageSpec)

    public var id: AnnotationID {
        switch self {
        case let .arrow(spec): spec.id
        case let .shape(spec): spec.id
        case let .line(spec): spec.id
        case let .freehand(spec): spec.id
        case let .highlighter(spec): spec.id
        case let .text(spec): spec.id
        case let .redaction(spec): spec.id
        case let .counter(spec): spec.id
        case let .crop(spec): spec.id
        case let .beautify(spec): spec.id
        case let .camera(spec): spec.id
        case let .progressiveBlur(spec): spec.id
        case let .measure(spec): spec.id
        case let .subjectLift(spec): spec.id
        case let .image(spec): spec.id
        }
    }

    /// The tool that made this annotation, used for style memory and the inspector.
    public var tool: AnnotationTool {
        switch self {
        case .arrow: .arrow
        case .shape: .shape
        case .line: .line
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .text: .text
        case .redaction: .redaction
        case .counter: .counter
        case .crop: .crop
        case .beautify: .beautify
        case .camera: .camera
        case .progressiveBlur: .progressiveBlur
        case .measure: .measure
        case .subjectLift: .subjectLift
        case .image: .image
        }
    }

    /// Whether the user can select and move this annotation.
    ///
    /// Crop and beautify define the canvas rather than sitting on it, so they are
    /// edited through their own chrome rather than by clicking the drawing.
    public var isSelectable: Bool {
        !tool.isCanvasChrome
    }
}

/// The editor's tools (docs/03 §3).
public enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case arrow
    case shape
    case line
    case freehand
    case highlighter
    case text
    case redaction
    case counter
    case crop
    case beautify
    case camera
    case progressiveBlur
    case measure
    case subjectLift
    case image

    public var title: String {
        switch self {
        case .arrow: "Arrow"
        case .shape: "Shape"
        case .line: "Line"
        case .freehand: "Pencil"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .redaction: "Blur"
        case .counter: "Counter"
        case .crop: "Crop"
        case .beautify: "Beautify"
        case .camera: "Perspective"
        case .progressiveBlur: "Progressive Blur"
        case .measure: "Measure"
        case .subjectLift: "Remove Background"
        case .image: "Image"
        }
    }

    /// Canvas chrome is edited through its own UI, not by dragging a shape on the image.
    public var isCanvasChrome: Bool {
        self == .crop || self == .beautify || self == .subjectLift || self == .camera
            || self == .progressiveBlur
    }

    /// Tools the pointer can draw with.
    ///
    /// Beautify and background removal are actions in the chrome rather than things you
    /// draw, and an image arrives by being dropped rather than by being drawn — but once
    /// it is there it selects and moves like anything else (docs/06 M24).
    public var isPointerTool: Bool {
        self != .beautify && self != .subjectLift && self != .image && self != .camera
            && self != .progressiveBlur
    }
}
