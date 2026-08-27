import AppKit
import OverlayKit
import Shared
import SwiftUI

/// The result toast after Capture Text (docs/03 §1.7).
///
/// Shows a preview and a character count so the user knows the recognition worked without
/// having to paste somewhere to find out — and offers Open for a QR payload that is a URL.
@MainActor
final class TextCaptureToast {
    private var panel: NonActivatingPanel?
    private static let size = CGSize(width: 340, height: 150)
    private static let margin: CGFloat = 20
    private var dismissTask: Task<Void, Never>?

    func show(text: String, codes: [DetectedCode], on screen: NSScreen?) {
        dismiss()

        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }

        let frame = CGRect(
            x: area.maxX - Self.size.width - Self.margin,
            y: area.maxY - Self.size.height - Self.margin,
            width: Self.size.width,
            height: Self.size.height
        )
        let panel = NonActivatingPanel(contentRect: frame, level: .floating)
        panel.contentView = NSHostingView(rootView: TextCaptureToastView(
            text: text,
            codes: codes,
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        panel.orderFrontRegardless()
        self.panel = panel

        // A toast that never goes away is litter; this one is transient by design.
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.dismiss()
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
    let onDismiss: () -> Void

    var body: some View {
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

            if text.isEmpty {
                Text("No text found in that region.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 60)
            }

            // A QR payload that is a link is the one case worth an action (docs/03 §1.7).
            if let url = codes.compactMap(\.url).first {
                HStack {
                    Button("Open Link") {
                        NSWorkspace.shared.open(url)
                        onDismiss()
                    }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        onDismiss()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
        if text.isEmpty, !codes.isEmpty {
            return "\(codes.count) code\(codes.count == 1 ? "" : "s") found"
        }
        let count = text.count
        return "Copied \(count) character\(count == 1 ? "" : "s")"
    }
}
