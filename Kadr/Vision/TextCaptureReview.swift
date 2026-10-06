import AppKit
import OverlayKit
import Shared
import SwiftUI

/// A review window after Capture Text (docs/03 §1.7).
///
/// The toast is a confirmation that copy happened. This is the place to edit, count, and
/// open a QR code — the same job a dedicated OCR result window does in other capture apps,
/// without uploading anything.
@MainActor
final class TextCaptureReview {
    private var panel: NSPanel?
    /// Retained because `NSWindow.delegate` is weak.
    private var closeHook: CloseHook?

    func show(text: String, codes: [DetectedCode], table: RecognizedTable? = nil) {
        dismiss()
        ActivationJuggler.shared.beginRegularWindow()

        let root = TextCaptureReviewView(
            text: text,
            codes: codes,
            table: table,
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 360)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = codes.isEmpty ? "Text Recognition" : "Text & Code Recognition"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 240)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        let hook = CloseHook { [weak self] in self?.dismiss() }
        panel.delegate = hook
        closeHook = hook
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        closeHook = nil
        panel.delegate = nil
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
        ActivationJuggler.shared.endRegularWindow()
    }
}

/// Forwards window-close into a closure so the review does not need to be an NSObject.
private final class CloseHook: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct TextCaptureReviewView: View {
    @State var text: String
    let codes: [DetectedCode]
    let table: RecognizedTable?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let table, table.isMeaningful {
                    Button("Copy as Table") { copy(table.tabSeparated) }
                    Button("Copy as Markdown") { copy(table.markdown) }
                }
                Button("Copy") { copy(text) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let url = codes.compactMap(\.url).first {
                HStack {
                    Button("Open Link") {
                        NSWorkspace.shared.open(url)
                    }
                    Button("Copy Link") {
                        copy(url.absoluteString)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summary: String {
        let characters = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        var parts = [
            KadrText.counted("^[\(characters) character](inflect: true)"),
            KadrText.counted("^[\(words) word](inflect: true)")
        ]
        if !codes.isEmpty {
            parts.append(KadrText.counted("^[\(codes.count) code](inflect: true)"))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
