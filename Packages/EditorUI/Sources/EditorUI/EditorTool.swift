import AnnotationModel
import Foundation

/// What the pointer does right now (docs/03 §3).
public enum EditorTool: Hashable, Sendable, CaseIterable {
    case select
    case arrow
    case shape
    case line
    case freehand
    case highlighter
    case text
    case redaction
    case counter
    case crop

    /// The annotation this tool draws, or `nil` for select.
    public var annotation: AnnotationTool? {
        switch self {
        case .select: nil
        case .arrow: .arrow
        case .shape: .shape
        case .line: .line
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .text: .text
        case .redaction: .redaction
        case .counter: .counter
        case .crop: .crop
        }
    }

    public var title: String {
        annotation?.title ?? "Select"
    }

    /// SF Symbol for the toolbar.
    public var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .shape: "rectangle"
        case .line: "line.diagonal"
        case .freehand: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .redaction: "drop.fill"
        case .counter: "1.circle.fill"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut, in the order a user would reach for them.
    public var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .shape: "r"
        case .line: "l"
        case .freehand: "p"
        case .highlighter: "h"
        case .text: "t"
        case .redaction: "b"
        case .counter: "c"
        case .crop: "k"
        }
    }

    /// Tools that place a fixed-size annotation with a single click rather than a drag.
    public var isClickToPlace: Bool {
        self == .counter
    }
}
