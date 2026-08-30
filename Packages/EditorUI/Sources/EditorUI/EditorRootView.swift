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
    private weak var subjectLift: (any SubjectLifting)?
    private let onExport: (ExportAction) -> Void

    @State private var canvasSession = EditorCanvasSession()
    @State private var isInspectorPresented = true

    /// What the toolbar's export controls ask for.
    public enum ExportAction: Sendable {
        case copy
        case copyWithoutAnnotations
        case save
        /// Write a re-editable `.kadr` rather than a flattened image (docs/06 M24).
        case saveProject
    }

    public init(
        model: EditorDocumentModel,
        baseImage: CGImage,
        redactionAssist: (any RedactionAssisting)? = nil,
        subjectLift: (any SubjectLifting)? = nil,
        onExport: @escaping (ExportAction) -> Void
    ) {
        self.model = model
        self.baseImage = baseImage
        self.redactionAssist = redactionAssist
        self.subjectLift = subjectLift
        self.onExport = onExport
    }

    public var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                model: model,
                isInspectorPresented: $isInspectorPresented,
                onExport: onExport,
                onAutoRedact: redactionAssist == nil ? nil : { Task { await runAutoRedact() } },
                onRemoveBackground: subjectLift == nil ? nil : { Task { await runSubjectLift() } }
            )
            if model.hasRedactionReviewChrome {
                Divider()
                EditorRedactionReviewStrip(model: model) {
                    Task { await runFind() }
                }
            }
            Divider()
            HStack(spacing: 0) {
                workspace
                if isInspectorPresented {
                    Divider()
                    EditorInspector(model: model)
                        .frame(width: EditorWindowGeometry.inspectorWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isInspectorPresented)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(zoomKeyCommands)
    }

    private var workspace: some View {
        ZStack {
            EditorWorkspaceBackground()
            EditorCanvasHost(
                model: model,
                baseImage: baseImage,
                session: canvasSession,
                isCropping: model.tool == .crop,
                zoomToFit: canvasSession.zoomToFit,
                magnification: canvasSession.magnification
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            EditorZoomControl(session: canvasSession)
                .padding(.leading, 16)
                .padding(.bottom, 16)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.tool == .crop {
                EditorCanvasSizeBadge(size: cropBadgeSize)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.tool)
    }

    private var cropBadgeSize: CGSize {
        let points = model.document.crop?.rect.size ?? model.document.canvasRect.size
        let scale = model.document.baseImage.scale
        return CGSize(width: points.width * scale, height: points.height * scale)
    }

    /// Menu shortcuts only fire when that menu is in the responder chain; these buttons
    /// keep Fit / actual size / zoom reachable from the canvas (docs/06 M7).
    private var zoomKeyCommands: some View {
        Group {
            Button("Zoom In") { canvasSession.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom In") { canvasSession.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { canvasSession.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Fit Canvas") { canvasSession.fit() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Actual Size") { canvasSession.setPercent(100) }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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

    /// Asks the helper for a subject mask and applies it.
    ///
    /// "No subject" is reported as a message rather than an error: a screenshot of a
    /// spreadsheet legitimately has nothing to lift, and calling that a failure would be
    /// blaming the user for the picture they took (docs/06 M23).
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
}
