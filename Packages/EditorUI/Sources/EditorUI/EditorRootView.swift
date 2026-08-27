import AnnotationModel
import AppKit
import SwiftUI

/// The editor window's content: toolbar, canvas, inspector (docs/03 §3).
///
/// SwiftUI drives only the chrome. The canvas is an `NSView` behind a representable,
/// because the drawing surface has to run at 60 fps and SwiftUI is the wrong tool for
/// that path (docs/04 §6).
public struct EditorRootView: View {
    @Bindable private var model: EditorDocumentModel
    private let baseImage: CGImage
    private let onExport: (ExportAction) -> Void

    /// What the toolbar's export controls ask for.
    public enum ExportAction: Sendable {
        case copy
        case copyWithoutAnnotations
        case save
    }

    public init(
        model: EditorDocumentModel,
        baseImage: CGImage,
        onExport: @escaping (ExportAction) -> Void
    ) {
        self.model = model
        self.baseImage = baseImage
        self.onExport = onExport
    }

    public var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, onExport: onExport)
            Divider()
            HStack(spacing: 0) {
                CanvasRepresentable(model: model, baseImage: baseImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                EditorInspector(model: model)
                    .frame(width: 240)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// Hosts the CALayer canvas inside SwiftUI.
private struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorDocumentModel
    let baseImage: CGImage

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = AnnotationCanvasView(model: model, baseImage: baseImage)
        let scrollView = NSScrollView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Pinch to zoom (docs/03 §3).
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = .underPageBackgroundColor
        context.coordinator.canvas = canvas
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // The document may have changed under us — undo, an inspector edit, a menu
        // command — so the layer tree is rebuilt from the model.
        context.coordinator.canvas?.documentChangedExternally()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var canvas: AnnotationCanvasView?
    }
}
