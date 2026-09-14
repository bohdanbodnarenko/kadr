import AnnotationModel
import AnnotationRender
import AppKit
import Foundation

/// Editing a text annotation where it sits (docs/03 §3, docs/09 U1.8).
///
/// A real `NSTextView` over the canvas rather than a panel beside it, laid out by the same
/// `TextLayout` the exporter uses. That is the whole point: the caret, the wrapping and the
/// pill are the exported ones, so what the user types is what comes out — as against a
/// field that approximates the result and reflows the moment it is committed.
///
/// AppKit owns this view outright (CLAUDE.md rule 4). It exists only between a
/// double-click and a commit, and is torn down completely afterwards.
@MainActor
final class TextOverlayEditor: NSObject, NSTextViewDelegate {
    /// The annotation being edited, and where it sits on the canvas.
    private(set) var editingID: AnnotationID?
    private var spec: TextSpec?
    private var textView: NSTextView?
    private var scrollHost: NSView?

    /// Called on every keystroke with the current string, so the document can follow.
    var onChange: ((AnnotationID, String) -> Void)?
    /// Called when editing ends, whether committed or abandoned.
    var onFinish: ((AnnotationID) -> Void)?

    var isEditing: Bool {
        editingID != nil
    }

    /// Starts editing `spec` inside `container`, in the container's own coordinates.
    func begin(editing spec: TextSpec, in container: NSView) {
        finish()

        let view = NSTextView(frame: frame(for: spec))
        view.delegate = self
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.drawsBackground = spec.style.backgroundColor != nil
        if let background = spec.style.backgroundColor {
            view.backgroundColor = NSColor(background)
        }
        view.textContainerInset = TextLayout.pillPadding(for: spec.style)
        view.textContainer?.lineFragmentPadding = 0
        view.font = NSFont(name: resolvedFontName(for: spec.style), size: spec.style.fontSize)
            ?? .systemFont(ofSize: spec.style.fontSize)
        view.textColor = NSColor(spec.style.color)
        view.insertionPointColor = NSColor(spec.style.color)
        view.alignment = Self.alignment(for: spec.style)
        view.string = spec.string
        view.wantsLayer = true
        view.layer?.cornerRadius = spec.style.backgroundColor == nil
            ? 0
            : TextLayout.pillRadius(for: spec.style)

        container.addSubview(view)
        container.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (spec.string as NSString).length, length: 0))

        textView = view
        scrollHost = container
        editingID = spec.id
        self.spec = spec
    }

    /// Ends editing and removes the field. Safe to call when nothing is being edited.
    func finish() {
        guard let editingID else { return }
        textView?.removeFromSuperview()
        textView = nil
        scrollHost = nil
        self.editingID = nil
        spec = nil
        onFinish?(editingID)
    }

    /// The field's frame for a spec: the pill if there is one, otherwise the text's own box.
    ///
    /// Measured through `TextLayout`, so the field is exactly as big as the export will be.
    func frame(for spec: TextSpec) -> CGRect {
        let box = TextLayout.pillRect(spec) ?? spec.rect
        let measured = TextLayout.measuredSize(spec, maxWidth: spec.rect.width)
        let padding = TextLayout.pillPadding(for: spec.style)
        return CGRect(
            x: box.minX,
            y: box.minY,
            width: box.width,
            height: max(box.height, measured.height + padding.height * 2)
        )
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let editingID, var spec, let textView else { return }
        spec.string = textView.string
        self.spec = spec
        // Grow with the text, using the export's own measurement rather than the text
        // view's — the two differ by a hair, and a hair is a reflow on commit.
        textView.frame = frame(for: spec)
        onChange?(editingID, spec.string)
    }

    /// Escape abandons; ⌘Return and clicking away commit. Return inserts a newline, because
    /// a text annotation is often two lines and there is no other way to type one.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), Selector(("insertNewlineIgnoringLineBreaks:")):
            finish()
            return true
        default:
            return false
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        finish()
    }

    /// The PostScript name the style resolves to, so AppKit picks the same face CoreText
    /// would.
    private func resolvedFontName(for style: TextStyle) -> String {
        style.isBold ? TextLayout.boldName(for: style.fontName) : style.fontName
    }

    /// The field lines its text up the way the exporter's paragraph style will.
    static func alignment(for style: TextStyle) -> NSTextAlignment {
        switch style.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}

extension NSColor {
    /// An `AnnotationColor` as an AppKit colour, in the sRGB space captures are tagged with.
    convenience init(_ color: AnnotationColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
