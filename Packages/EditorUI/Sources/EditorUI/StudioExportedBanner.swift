import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Exported · Show in Finder", in the studio window rather than in Finder (docs/18 STU-13).
///
/// Every export used to bring Finder forward with the file selected, which is a context
/// switch nobody asked for after the tenth export of a session. The banner names the file,
/// offers the reveal, and is itself the file: drag the icon into Mail or Slack.
struct StudioExportedBanner: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help(Text("Drag the exported file anywhere", bundle: .module))
                .accessibilityLabel(Text("Exported file", bundle: .module))
                .accessibilityHint(Text("Drag to share it", bundle: .module))
            VStack(alignment: .leading, spacing: 1) {
                Text("Exported", bundle: .module)
                    .font(.callout.weight(.semibold))
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Show in Finder", bundle: .module)) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                onDismiss()
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(Text("Dismiss", bundle: .module))
            .accessibilityLabel(Text("Dismiss", bundle: .module))
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Exported \(url.lastPathComponent)", bundle: .module))
    }
}

extension View {
    /// The exported banner at the bottom of the studio, while the file still exists.
    func studioExportedBanner(model: StudioDocumentModel, reduceMotion: Bool) -> some View {
        overlay(alignment: .bottom) {
            if let url = model.lastExportedURL, FileManager.default.fileExists(atPath: url.path) {
                StudioExportedBanner(url: url) { model.lastExportedURL = nil }
                    .frame(maxWidth: 460)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.lastExportedURL)
    }
}

/// Hands the Share button's view to the model, so the share picker opens from the button
/// and not from whichever window is key when the render finishes (docs/17 T-STU-4).
struct StudioShareAnchor: NSViewRepresentable {
    let model: StudioDocumentModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        model.shareAnchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        model.shareAnchorView = nsView
    }
}
