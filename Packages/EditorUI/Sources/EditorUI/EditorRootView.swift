import AnnotationModel
import AppKit
import Shared
import SwiftUI

/// The editor window's content: toolbar, canvas, inspector (docs/03 §3).
///
/// SwiftUI drives only the chrome. The canvas is an `NSView` behind a representable,
/// because the drawing surface has to run at 60 fps and SwiftUI is the wrong tool for
/// that path (docs/04 §6).
public struct EditorRootView: View {
    @Bindable private var model: EditorDocumentModel
    private let baseImage: CGImage
    private weak var redactionAssist: (any RedactionAssisting)?
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
        redactionAssist: (any RedactionAssisting)? = nil,
        onExport: @escaping (ExportAction) -> Void
    ) {
        self.model = model
        self.baseImage = baseImage
        self.redactionAssist = redactionAssist
        self.onExport = onExport
    }

    public var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                model: model,
                onExport: onExport,
                onAutoRedact: redactionAssist == nil ? nil : { Task { await runAutoRedact() } }
            )
            if model.hasRedactionReviewChrome {
                Divider()
                EditorRedactionReviewStrip(model: model) {
                    Task { await runFind() }
                }
            }
            Divider()
            HStack(spacing: 0) {
                CanvasRepresentable(model: model, baseImage: baseImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                EditorInspector(model: model)
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func runAutoRedact() async {
        guard let redactionAssist else { return }
        model.startRedactionSearch()
        do {
            let analysis = try await redactionAssist.analyzeForRedaction(baseImage)
            model.beginRedactionReview(analysis)
        } catch {
            model.failRedactionReview(error.localizedDescription)
        }
    }

    private func runFind() async {
        if model.recognizedLines.isEmpty {
            await runAutoRedact()
            return
        }
        model.stageQueryMatches()
        model.reopenRedactionReview()
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

        if !context.coordinator.hasChosenInitialZoom, scrollView.bounds.width > 1 {
            context.coordinator.hasChosenInitialZoom = true
            fitToWidthIfTall(scrollView)
        }
    }

    /// Scrolled-canvas mode: a stitched page opens fitted to the width, at the top
    /// (docs/03 §1.6).
    ///
    /// A scrolling capture is thousands of pixels tall and a few hundred wide, and opening
    /// it at 100% shows a corner of it. Fitting the width is the only view of such a page
    /// that means anything; ordinary captures are left alone, because shrinking a normal
    /// screenshot to fit is worse than showing it as it is.
    private func fitToWidthIfTall(_ scrollView: NSScrollView) {
        let width = CGFloat(baseImage.width)
        let height = CGFloat(baseImage.height)
        guard width > 0, height > width * 2 else { return }

        let magnification = min(1, scrollView.contentSize.width / width)
        scrollView.magnification = magnification
        // The canvas is flipped, so the top of the page is y = 0.
        scrollView.documentView?.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var canvas: AnnotationCanvasView?
        /// The initial zoom is chosen once, from the first real layout; after that the
        /// magnification belongs to the user.
        var hasChosenInitialZoom = false
    }
}
