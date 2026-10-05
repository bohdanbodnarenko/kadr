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
        case .arrow: String(localized: "Arrow", bundle: .module)
        case .shape: String(localized: "Shape", bundle: .module)
        case .line: String(localized: "Line", bundle: .module)
        case .freehand: String(localized: "Pencil", bundle: .module)
        case .highlighter: String(localized: "Highlighter", bundle: .module)
        case .text: String(localized: "Text", bundle: .module)
        case .redaction: String(localized: "Blur", bundle: .module)
        case .spotlight: String(localized: "Spotlight", bundle: .module)
        case .counter: String(localized: "Counter", bundle: .module)
        case .crop: String(localized: "Crop", bundle: .module)
        case .beautify: String(localized: "Beautify", bundle: .module)
        case .camera: String(localized: "Perspective", bundle: .module)
        case .progressiveBlur: String(localized: "Progressive Blur", bundle: .module)
        case .watermark: String(localized: "Watermark", bundle: .module)
        case .measure: String(localized: "Measure", bundle: .module)
        case .subjectLift: String(localized: "Remove Background", bundle: .module)
        case .image: String(localized: "Image", bundle: .module)
        }
    }

    /// Canvas chrome is edited through its own UI, not by dragging a shape on the image.
    public var isCanvasChrome: Bool {
        self == .crop || self == .beautify || self == .subjectLift || self == .camera
            || self == .progressiveBlur || self == .watermark
    }
}
