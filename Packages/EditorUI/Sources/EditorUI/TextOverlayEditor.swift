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
    /// Who had the keyboard before the field took it — the canvas, in practice.
    private weak var responderBeforeEditing: NSResponder?

    /// Called on every keystroke with the current string, so the document can follow.
    var onChange: ((AnnotationID, String) -> Void)?
    /// Called when editing ends. Editing always commits; Undo is the way back (T-ED-4).
    var onFinish: ((AnnotationID) -> Void)?

    var isEditing: Bool {
        editingID != nil
    }

    /// Starts editing `spec` inside `container`, in the container's own coordinates.
    func begin(editing spec: TextSpec, in container: NSView) {
        finish()

        let view = CommittingTextView(frame: frame(for: spec))
        view.delegate = self
        view.onCommit = { [weak self] in self?.finish() }
        view.isRichText = false
        // ⌘Z inside the field undoes typing, in the field's own history; it no longer
        // reaches the document and removes the box under the live field (docs/18 ED-5).
        view.allowsUndo = true
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
        responderBeforeEditing = container.window?.firstResponder
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
        let view = textView
        let host = scrollHost
        let restore = responderBeforeEditing

        // State goes first, because tearing the field down ends editing, and ending editing
        // calls straight back in here through `textDidEndEditing`.
        self.editingID = nil
        spec = nil
        textView = nil
        scrollHost = nil
        responderBeforeEditing = nil

        let window = view?.window ?? host?.window
        view?.removeFromSuperview()
        // Hand the keyboard back. Removing the first responder from its superview leaves the
        // *window* holding focus, and a window answers none of the canvas's keys — so every
        // tool letter, arrow nudge and Delete stopped working the moment a caption had been
        // typed, until the canvas was clicked again (docs/09 U1.8).
        if let window {
            let next = restore.flatMap { $0 === window ? nil : $0 } ?? host
            window.makeFirstResponder(next)
        }
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

    /// Escape, ⌘Return, Enter and clicking away all commit. Return inserts a newline,
    /// because a text annotation is often two lines and there is no other way to type one.
    ///
    /// Escape used to revert to the original string, which deleted a caption the user had
    /// just typed. Keynote, Preview and Figma commit on Escape and leave the rest to Undo,
    /// and so does this (T-ED-4).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
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

/// The field itself, which commits on ⌘Return and on the keypad's Enter (T-ED-4).
///
/// Handled as a key equivalent: no key binding sends a selector for ⌘Return, so a
/// `doCommandBy` match on one never fired.
final class CommittingTextView: NSTextView {
    var onCommit: (() -> Void)?

    /// The field's own history. Registered on the window's manager, typing would outlive
    /// the field and later ⌘Z presses would replay keystrokes into nothing.
    private let fieldUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        fieldUndoManager
    }

    /// First in the responder chain while editing, so Edit ▸ Undo lands here, not on the
    /// window controller's document undo.
    @objc func undo(_ sender: Any?) {
        fieldUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        fieldUndoManager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): fieldUndoManager.canUndo
        case #selector(redo(_:)): fieldUndoManager.canRedo
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           Self.isCommitKey(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isCommitKey(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76

    /// ⌘Return, or Enter on the keypad. A plain Return is a newline.
    static func isCommitKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case returnKeyCode: return relevant == .command
        case keypadEnterKeyCode: return relevant.isEmpty
        default: return false
        }
    }
}

extension NSColor {
    /// An `AnnotationColor` as an AppKit colour, in the sRGB space captures are tagged with.
    convenience init(_ color: AnnotationColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
