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
    @State private var showsCopiedToast = false

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
                onExport: handleExport,
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
            // The system's inspector column, not a panel of our own (docs/03 §3).
            //
            // This was an `HStack` with a `Divider` and a hard-coded width, which meant
            // re-implementing — badly — what `NSSplitViewItem`'s inspector behaviour already
            // does: a divider the user can drag, a width that holds against window resizes,
            // the right material against the window background, and a collapse that animates
            // the way every other macOS inspector animates. A hand-rolled one is a panel that
            // merely looks like an inspector until the user tries to drag its edge.
            workspace
                .inspector(isPresented: $isInspectorPresented) {
                    EditorInspector(model: model)
                        .inspectorColumnWidth(
                            min: EditorWindowGeometry.inspectorMinWidth,
                            ideal: EditorWindowGeometry.inspectorWidth,
                            max: EditorWindowGeometry.inspectorMaxWidth
                        )
                }
        }
        .overlay {
            if showsCopiedToast {
                EditorCopiedToast()
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: showsCopiedToast)
        .frame(minWidth: 720, minHeight: 480)
        .background(zoomKeyCommands)
        .onChange(of: model.tool) { _, tool in
            if tool == .highlighter {
                Task { await prepareSmartHighlighter() }
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
                    .animation(.easeInOut(duration: 0.15), value: model.tool)
            }
        }
    }

    private var cropBadgeSize: CGSize {
        let points = model.cropWorkingRect.size
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
            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Duplicate") { model.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Paste") { pasteAnnotations() }
                .keyboardShortcut("v", modifiers: .command)
            Button("Copy Flattened") { handleExport(.copyFlattened) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Print") { handleExport(.print) }
                .keyboardShortcut("p", modifiers: .command)
            Button("Lock Objects") { model.isCanvasLocked.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Increase Tool Size") { model.adjustToolSize(by: 1) }
                .keyboardShortcut("=", modifiers: .shift)
            Button("Decrease Tool Size") { model.adjustToolSize(by: -1) }
                .keyboardShortcut("`", modifiers: [])
            Button("Insert Image") { handleExport(.insertImage) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Insert from Clipboard") { handleExport(.insertFromClipboard) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func handleExport(_ action: ExportAction) {
        if action == .copy, copyAnnotationsIfSelected() {
            showsCopiedToast = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1400))
                showsCopiedToast = false
            }
            return
        }
        onExport(action)
        guard action == .copy || action == .copyFlattened || action == .copyWithoutAnnotations else {
            return
        }
        showsCopiedToast = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            showsCopiedToast = false
        }
    }

    /// ⌘C copies selected annotations rather than flattening the capture (CleanShot 4.4).
    @discardableResult
    private func copyAnnotationsIfSelected() -> Bool {
        guard let data = model.encodedSelection() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .kadrAnnotations)
        return true
    }

    private func pasteAnnotations() {
        guard let data = NSPasteboard.general.data(forType: .kadrAnnotations) else { return }
        _ = model.pasteEncoded(data)
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

    /// OCR for the smart highlighter, without opening the redaction review strip.
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
            // Freehand still works when the helper cannot read the capture.
        }
    }
}

extension NSPasteboard.PasteboardType {
    /// Annotation objects copied from the editor (CleanShot 4.4).
    static let kadrAnnotations = NSPasteboard.PasteboardType("app.kadr.annotations.json")
}
