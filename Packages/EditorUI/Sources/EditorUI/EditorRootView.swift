import AnnotationModel
import AppKit
import ControlKit
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
    private weak var subjectLift: (any SubjectLifting)?
    private let onExport: (ExportAction) -> Void
    private let onRetryExport: (EditorExportAction) -> Void
    private let onChooseExportLocation: (EditorExportAction) -> Void
    /// Moves the capture to the Trash; the host asks first. Nil hides the button.
    private let onDelete: (() -> Void)?

    private let canvasSession: EditorCanvasSession

    /// What the toolbar's export controls ask for.
    public enum ExportAction: Equatable, Sendable {
        case copy
        /// Flattened image, even when annotations are selected (CleanShot ⌘⇧C).
        case copyFlattened
        case copyWithoutAnnotations
        case save
        /// Flattened image to a path the user picks (CleanShot §8.5).
        case saveAs
        /// Write a re-editable `.kadr` rather than a flattened image (docs/06 M24).
        case saveProject
        case print
        case pin
        case share
        case insertImage
        case insertFromClipboard
    }

    public init(
        model: EditorDocumentModel,
        baseImage: CGImage,
        canvasSession: EditorCanvasSession = EditorCanvasSession(),
        redactionAssist: (any RedactionAssisting)? = nil,
        subjectLift: (any SubjectLifting)? = nil,
        onExport: @escaping (ExportAction) -> Void,
        onRetryExport: @escaping (EditorExportAction) -> Void = { _ in },
        onChooseExportLocation: @escaping (EditorExportAction) -> Void = { _ in },
        onDelete: (() -> Void)? = nil
    ) {
        self.model = model
        self.baseImage = baseImage
        self.canvasSession = canvasSession
        self.redactionAssist = redactionAssist
        self.subjectLift = subjectLift
        self.onExport = onExport
        self.onRetryExport = onRetryExport
        self.onChooseExportLocation = onChooseExportLocation
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                model: model,
                isInspectorPresented: $model.isInspectorPresented,
                onExport: onExport,
                onAutoRedact: redactionAssist == nil ? nil : { Task { await runAutoRedact() } },
                onRemoveBackground: subjectLift == nil ? nil : { Task { await runSubjectLift() } },
                onDelete: onDelete
            )
            Divider()
            workspace
                .inspector(isPresented: $model.isInspectorPresented) {
                    EditorInspector(model: model)
                        // Named so VoiceOver says where it is, not just "group" (docs/18 UX-02).
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Inspector", bundle: .module))
                        .accessibilityIdentifier(EditorAccessibilityID.inspector)
                        .inspectorColumnWidth(
                            min: EditorWindowGeometry.inspectorMinWidth,
                            ideal: EditorWindowGeometry.inspectorWidth,
                            max: EditorWindowGeometry.inspectorMaxWidth
                        )
                }
        }
        .overlay {
            if model.showsCopiedToast {
                EditorCopiedToast()
                    .transition(EditorMotion.transition(.scale(scale: 0.92).combined(with: .opacity)))
            }
        }
        .editorAnimation(KadrMotion.snap, value: model.showsCopiedToast)
        .frame(minWidth: EditorWindowGeometry.minSize.width, minHeight: EditorWindowGeometry.minSize.height)
        .editorLayoutDirection()
        .onChange(of: model.tool) { _, tool in
            if tool == .highlighter {
                Task { await prepareSmartHighlighter() }
            }
        }
        .onChange(of: model.showsCopiedToast) { _, show in
            guard show else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1400))
                model.clearCopyToast()
            }
        }
    }

    private var workspace: some View {
        ZStack {
            EditorWorkspaceBackground()
            EditorCanvasHost(
                model: model,
                baseImage: baseImage,
                session: canvasSession,
                isCropping: model.tool == .crop,
                zoomToFit: canvasSession.zoomToFit
            )
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Everything transient floats over the canvas. Nothing here takes layout space from
        // it, so no banner, crop bar or progress message can shrink the viewport and re-fit
        // the capture under the user.
        .overlay(alignment: .top) {
            EditorWorkspaceBanners(
                model: model,
                onRetry: onRetryExport,
                onChooseAnotherLocation: onChooseExportLocation,
                onFind: { Task { await runFind() } }
            )
            .padding(.top, KadrSpace.large)
            .padding(.horizontal, KadrSpace.xl)
        }
        .overlay(alignment: .bottomLeading) {
            EditorZoomControl(session: canvasSession)
                .padding(.leading, KadrSpace.xl)
                .padding(.bottom, KadrSpace.xl)
        }
        .overlay(alignment: .bottom) {
            EditorCropChrome(model: model)
                .padding(.bottom, 14)
        }
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

    private func runSubjectLift() async {
        guard let subjectLift else { return }
        if model.hasSubjectLift {
            model.removeSubjectLift()
            return
        }
        model.startSubjectLift()
        do {
            guard let mask = try await subjectLift.liftSubject() else {
                model.failSubjectLift("Kadr could not find a subject in this capture.")
                return
            }
            model.applySubjectLift(maskPNG: mask)
        } catch {
            model.failSubjectLift(error.localizedDescription)
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

    private func prepareSmartHighlighter() async {
        guard let redactionAssist else { return }
        guard model.highlightBoxes.isEmpty else { return }
        if !model.recognizedLines.isEmpty {
            model.loadHighlightLayout(from: VisionAnalysis(
                lines: model.recognizedLines,
                words: model.recognizedWords
            ))
            return
        }
        do {
            let analysis = try await redactionAssist.analyzeForRedaction(baseImage)
            model.loadHighlightLayout(from: analysis)
        } catch {
            model.highlighterFallback = "Smart highlighting is unavailable, so Kadr will use freehand."
        }
    }
}

public extension NSPasteboard.PasteboardType {
    /// Annotation objects copied from the editor (CleanShot 4.4).
    static let kadrAnnotations = NSPasteboard.PasteboardType("app.kadr.annotations.json")
}
