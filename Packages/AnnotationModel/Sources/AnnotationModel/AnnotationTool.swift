import Foundation

/// The editor's tools (docs/03 §3).
public enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case arrow
    case shape
    case line
    case freehand
    case highlighter
    case text
    case redaction
    case spotlight
    case counter
    case crop
    case beautify
    case camera
    case progressiveBlur
    case watermark
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
        case .spotlight: "Spotlight"
        case .counter: "Counter"
        case .crop: "Crop"
        case .beautify: "Beautify"
        case .camera: "Perspective"
        case .progressiveBlur: "Progressive Blur"
        case .watermark: "Watermark"
        case .measure: "Measure"
        case .subjectLift: "Remove Background"
        case .image: "Image"
        }
    }

    /// Canvas chrome is edited through its own UI, not by dragging a shape on the image.
    public var isCanvasChrome: Bool {
        self == .crop || self == .beautify || self == .subjectLift || self == .camera
            || self == .progressiveBlur || self == .watermark
    }
}
