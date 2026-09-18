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
    case spotlight
    case counter
    case crop
    case measure
    case sticker

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
        case .spotlight: .spotlight
        case .counter: .counter
        case .crop: .crop
        case .measure: .measure
        case .sticker: .image
        }
    }

    public var title: String {
        switch self {
        case .sticker: "Sticker"
        default: annotation?.title ?? "Select"
        }
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
        case .spotlight: "circle.lefthalf.filled"
        case .counter: "1.circle.fill"
        case .crop: "crop"
        case .measure: "ruler"
        case .sticker: "face.smiling"
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
        case .spotlight: "s"
        case .counter: "c"
        case .crop: "k"
        case .measure: "m"
        case .sticker: "e"
        }
    }

    /// Tools that place a fixed-size annotation with a single click rather than a drag.
    public var isClickToPlace: Bool {
        self == .counter || self == .sticker
    }

    /// Whether finishing a stroke should put the pointer back on Select.
    ///
    /// One-shot geometry — arrow, rectangle, line, text, blur — is almost always
    /// adjusted after placing, so the tool hands off to the cursor. Repeatable tools stay
    /// armed: a numbered badge is one of a sequence, a
    /// pencil stroke is rarely the last, and Crop is a mode rather than a stroke.
    public var returnsToSelectAfterUse: Bool {
        switch self {
        case .arrow, .shape, .line, .text, .redaction, .spotlight:
            true
        case .select, .freehand, .highlighter, .counter, .crop, .measure, .sticker:
            false
        }
    }
}
