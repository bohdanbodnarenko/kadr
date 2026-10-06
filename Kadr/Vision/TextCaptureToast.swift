import AppKit
import ControlKit
import OverlayKit
import Shared
import SwiftUI

/// The result toast after Capture Text (docs/03 §1.7).
///
/// The whole report, in the corner: how many lines went to the clipboard, the first of them
/// so the recognition can be trusted without pasting somewhere to check, and the two actions
/// worth offering — a table as a grid, a QR link to open. Edit is there for the capture that
/// does need fixing, which is the rare one; it used to be a window every capture had to be
/// dismissed from before the text could be pasted.
@MainActor
final class TextCaptureToast {
    private var panel: NonActivatingPanel?
    private static let width: CGFloat = 320
    private static let margin: CGFloat = 20
    private var dismissTask: Task<Void, Never>?

    /// - Parameters:
    ///   - table: a table found in the capture, which unlocks "Copy as Table"
    ///     (macOS 26+, docs/06 M25).
    ///   - lineCount: rows as the recogniser saw them, which is what the toast reports.
    ///   - onEdit: opens the review window. Omitted when there is nothing to edit.
    func show(
        text: String,
        codes: [DetectedCode],
        table: RecognizedTable? = nil,
        lineCount: Int = 0,
        on screen: NSScreen?,
        onEdit: (() -> Void)? = nil
    ) {
        dismiss()

        let screen = screen ?? ActiveScreen.resolve()
        guard let area = screen?.visibleFrame else { return }

        // The width is fixed on the SwiftUI view, not on the panel, so `fittingSize` is the
        // height this content needs *at this width* rather than its natural one.
        let hosting = NSHostingView(rootView: TextCaptureToastView(
            text: text,
            codes: codes,
            table: table,
            lineCount: lineCount,
            onEdit: onEdit.map { edit in
                { [weak self] in
                    self?.dismiss()
                    edit()
                }
            },
            onDismiss: { [weak self] in self?.dismiss() },
            onHover: { [weak self] inside in self?.pointerInside(inside) }
        ).frame(width: Self.width))
        hosting.sizingOptions = .intrinsicContentSize
        // Sized to what it has to say: a fixed 190 points left a band of empty material
        // under a two-line result, which is what made it read as a window rather than a
        // toast.
        let size = CGSize(width: Self.width, height: hosting.fittingSize.height)
        hosting.frame = NSRect(origin: .zero, size: size)

        let frame = CGRect(
            x: area.maxX - size.width - Self.margin,
            y: area.maxY - size.height - Self.margin,
            width: size.width,
            height: size.height
        )
        let panel = NonActivatingPanel(contentRect: frame, level: .floating)
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel

        scheduleDismiss()
    }

    /// A toast that never goes away is litter; this one is transient by design.
    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Holds still while the pointer is on it, so a result being read — or a Copy as Table
    /// being reached for — does not vanish under the pointer (WCAG 2.2.1, docs/17 T-CAP-12).
    /// The five seconds start again when the pointer leaves.
    private func pointerInside(_ inside: Bool) {
        guard panel != nil else { return }
        if inside {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct TextCaptureToastView: View {
    let text: String
    let codes: [DetectedCode]
    let table: RecognizedTable?
    let lineCount: Int
    let onEdit: (() -> Void)?
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        content
            .onHover(perform: onHover)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: "text.viewfinder")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)

            if !text.isEmpty {
                Text("\(text.count) characters on the clipboard")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if text.isEmpty {
                Text("No text found in that region.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // A glance at what was copied, not the whole of it: the clipboard has the
                // whole of it, and a scrollable transcript in a toast is a window.
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A screenshot of a table is one of the most annoying things to retype, and
            // the recogniser can see the grid — so offer the grid (docs/06 M25).
            if let table, table.isMeaningful {
                HStack {
                    Button("Copy as Table") {
                        copy(table.tabSeparated)
                    }
                    .help("Tab-separated, ready to paste into a spreadsheet")
                    Button("Copy as Markdown") {
                        copy(table.markdown)
                    }
                    Text("\(table.rowCount)×\(table.columnCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // A QR payload that is a link is the one case worth an action (docs/03 §1.7).
            if let url = codes.compactMap(\.url).first {
                HStack {
                    Button("Open Link") {
                        NSWorkspace.shared.open(url)
                        onDismiss()
                    }
                    .accessibilityLabel("Open link \(url.absoluteString)")
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        onDismiss()
                    }
                    .accessibilityLabel("Copy link")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let onEdit, !text.isEmpty {
                Button("Edit…", action: onEdit)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Open the recognized text to correct it before pasting")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .padding(KadrSpace.large)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KadrRadius.panel))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        onDismiss()
    }

    /// What happened, in the words the user would use: rows, and that they are on the
    /// clipboard. The character count is the detail underneath, for the capture where the
    /// number of lines is not the interesting part.
    private var title: String {
        if text.isEmpty, !codes.isEmpty {
            return KadrPlural.codes(codes.count) + " found"
        }
        if text.isEmpty {
            return KadrText.string("No text found")
        }
        return KadrText.string("\(KadrPlural.lines(max(lineCount, 1))) copied")
    }
}
