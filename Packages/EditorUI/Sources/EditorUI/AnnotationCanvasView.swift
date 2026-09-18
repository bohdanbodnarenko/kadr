import AnnotationModel
import AnnotationRender
import AppKit
import ImageIO
import QuartzCore
import Shared

/// The editor canvas: the capture, the annotations, and the pointer (docs/04 §6).
///
/// A CALayer tree, not SwiftUI. Dragging an annotation on a 5K capture has to hold 60 fps
/// (docs/03 §3), and that means mutating exactly one layer's path per event — no view
/// body re-evaluation, no layout pass, no diffing.
@MainActor
public final class AnnotationCanvasView: NSView {
    /// Several members are internal rather than private: the drop handling lives in
    /// `AnnotationCanvasView+Drop.swift` and the beautify chrome in
    /// `AnnotationCanvasView+Chrome.swift`, and `private` is file-scoped.
    let model: EditorDocumentModel
    let backdropLayer = CALayer()
    let gradientLayer = CAGradientLayer()
    let shadowLayer = CALayer()
    /// The exported image's edge: a soft shadow under the backdrop, so a white Beautify
    /// background reads as the picture rather than as a flat slab on the workspace.
    let canvasEdgeLayer = CALayer()
    /// The zoom the edge shadow was last sized for; it is held constant on screen.
    var canvasEdgeMagnification: CGFloat = 1
    /// Shows the whole canvas rendered through the export path, for the chrome that
    /// cannot be drawn as layers: the perspective camera and the progressive blur
    /// (docs/09 U1.2, U1.3).
    let cameraLayer = CALayer()
    /// Keeps that render off the drag path — stale-but-stretched while a slider moves,
    /// exact once it stops (docs/09 U1.3).
    private(set) lazy var chromeSettle = SettlePreview { [weak self] in
        self?.renderExpensiveChrome()
    }

    /// Which offscreen render is the current one (docs/10 R1.5).
    ///
    /// The render runs off the main actor, so two can be in flight — release one slider
    /// and touch the next before the first finishes. Without this the older result arrives
    /// second and leaves a stale picture on screen.
    var chromeRenderGeneration: UInt64 = 0
    /// The offscreen render in flight, so a newer one can cancel it (docs/10 R1.5).
    var chromeRenderTask: Task<Void, Never>?
    /// The pixels-per-point the latest offscreen render was asked for, so zooming in past
    /// it asks for a sharper one.
    var chromeRenderedScale: CGFloat = 0

    /// Edits a text annotation where it sits, laid out by the exporter's own metrics
    /// (docs/09 U1.8).
    private(set) lazy var textEditor: TextOverlayEditor = {
        let editor = TextOverlayEditor()
        editor.onChange = { [weak self] id, string in
            self?.model.updateText(id, string: string)
        }
        editor.onFinish = { [weak self] id in
            guard let self else { return }
            model.commitTextEdit(id)
            layers[id]?.isHidden = false
            // A sync, not a rebuild: the edited label redraws because its text changed,
            // and an emptied one is removed because membership did (docs/10 R1).
            documentChangedExternally()
        }
        return editor
    }()

    let contentHost = CALayer()
    let baseLayer = CALayer()
    let annotationLayer = CALayer()
    let compositeSpotlightLayer = CALayer()
    let watermarkLayer = WatermarkLayer()
    let bindingHintLayer = CAShapeLayer()
    let reviewLayer = CALayer()
    let draftLayer = CALayer()
    let selectionLayer = CALayer()
    let cropLayer = CALayer()
    /// Hosts every drawing layer so rotate/flip can transform them as one (docs/03 §3 P2).
    let drawingHost = CALayer()
    /// The density the vector chrome was last rasterised at, so a zoom that changes nothing
    /// does not walk every layer.
    var lastContentsScale: CGFloat = 0
    private let logger = KadrLog.logger(.overlay)
    let signposter = KadrLog.signposter(.overlay)

    /// Layers by annotation, so an update finds its own layer without a search.
    var layers: [AnnotationID: CALayer] = [:]
    var draftShapeLayer: CALayer?
    /// A freehand or highlighter draft's path so far, extended point by point.
    ///
    /// Rebuilding the whole polyline (and re-smoothing it) on every mouse-move made a long
    /// stroke quadratic; the draft is drawn raw and smoothed once it is committed.
    var draftPath: CGMutablePath?
    var draftPathPointCount = 0
    var draftPathID: AnnotationID?
    /// The document state the layer tree was last brought up to date with.
    var lastSyncKey: CanvasSyncKey?
    /// Selection handles, reused from event to event rather than rebuilt (docs/10 R1).
    var handleLayers: [CALayer] = []
    let selectionOutlineLayer = CAShapeLayer()
    /// Hover preview for a snapped highlighter stroke.
    var highlightPreviewLayer: CALayer?
    /// Kept so the measure tool can read the image's straight edges the first time it is
    /// used — never at open, because most sessions never measure anything (docs/06 M21).
    let baseImage: CGImage
    /// What the canvas is showing: the capture, or the capture with the subject cut out.
    /// Redaction samples this so a blur lands on the pixels the user sees.
    private(set) var displayedImage: CGImage
    private let subjectLift = SubjectLiftCompositor()
    /// Where redaction previews come from: the pixels on screen, and the renders made
    /// from them. Replaced when those pixels change; releasing it clears its cache entries.
    private(set) var redactionSource: RedactionPreviewSource
    /// The lift the base layer currently shows, so the composite is not redone per edit.
    private var liftedFrom: SubjectLiftSpec?
    var marqueeLayer = CAShapeLayer()
    /// Space-drag pans the canvas the way a hand tool does in every other image editor.
    var spaceIsDown = false
    var spacePanAnchor: CGPoint?
    /// Last chrome layout, so a style-only inspector tick does not re-lay the whole card.
    var lastLayoutKey: CanvasLayoutKey?
    var spacePanClipOrigin: CGPoint?
    /// Pointer location in image space, for Select-mode hover cursors (docs/16 ED-12).
    var lastHoverImagePoint: CGPoint?

    /// Called whenever the document changes, so the window can update its title bar.
    public var onDocumentChanged: (() -> Void)?

    public init(model: EditorDocumentModel, baseImage: CGImage) {
        self.model = model
        self.baseImage = baseImage
        displayedImage = baseImage
        redactionSource = RedactionPreviewSource(image: baseImage, scale: model.document.baseImage.scale)
        super.init(frame: CGRect(origin: .zero, size: model.document.baseImage.size))
        observeRedactionPreviews()

        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor
        root.isOpaque = false

        drawingHost.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.addSublayer(drawingHost)

        canvasEdgeLayer.isHidden = true
        drawingHost.addSublayer(canvasEdgeLayer)
        backdropLayer.addSublayer(gradientLayer)
        drawingHost.addSublayer(backdropLayer)
        drawingHost.addSublayer(shadowLayer)

        baseLayer.contents = baseImage
        baseLayer.magnificationFilter = .trilinear
        contentHost.addSublayer(baseLayer)
        drawingHost.addSublayer(contentHost)
        drawingHost.addSublayer(compositeSpotlightLayer)
        // Drawn on the canvas, not inside the card: arrows and shapes belong on the
        // beautify padding as well as on the screenshot (docs/03 §3).
        for layer in [annotationLayer, reviewLayer, draftLayer, selectionLayer, cropLayer] {
            layer.masksToBounds = false
            drawingHost.addSublayer(layer)
        }
        watermarkLayer.masksToBounds = true
        drawingHost.addSublayer(watermarkLayer)
        cameraLayer.isHidden = true
        drawingHost.addSublayer(cameraLayer)

        bindingHintLayer.fillColor = nil
        bindingHintLayer.strokeColor = NSColor.controlAccentColor.cgColor
        bindingHintLayer.lineWidth = 2
        bindingHintLayer.lineDashPattern = [4, 3]
        bindingHintLayer.isHidden = true
        selectionLayer.addSublayer(bindingHintLayer)

        selectionOutlineLayer.fillColor = nil
        selectionOutlineLayer.lineDashPattern = [3, 3]
        selectionOutlineLayer.isHidden = true
        selectionLayer.addSublayer(selectionOutlineLayer)

        marqueeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marqueeLayer.lineDashPattern = [4, 4]
        selectionLayer.addSublayer(marqueeLayer)

        layoutCanvasChrome()
        rebuildAnnotationLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnnotationCanvasView is created in code only")
    }

    /// Top-left origin, matching the annotation model, so no command has to think about
    /// CoreGraphics' flipped space.
    override public var isFlipped: Bool {
        true
    }

    override public var isOpaque: Bool {
        false
    }

    override public var acceptsFirstResponder: Bool {
        true
    }

    /// First click on an inactive editor must count, the same as the overlay cards.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Takes the keyboard as soon as the canvas is in a window.
    ///
    /// Without this the canvas only became first responder on `mouseDown`, so a freshly
    /// opened editor answered none of its keys — V, R, T, the arrows, Delete and Esc all
    /// did nothing until the user happened to click the image (docs/09 U1).
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.firstResponder === window else { return }
        window.makeFirstResponder(self)
    }

    // MARK: - Layer tree

    /// Rebuilds every annotation layer. Used after undo, deletion or reordering — not
    /// during a drag, which touches one layer.
    public func rebuildAnnotationLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        annotationLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()

        let scale = window?.backingScaleFactor ?? 2
        updateCompositeSpotlight()
        updateWatermarkLayer()
        // Resolved, so a bound arrow is drawn against its target's current geometry
        // rather than against the endpoint it was stored with (docs/09 U1.7).
        let context = layerContext(canvasRect: model.document.canvasRect, isLive: false)
        for command in model.document.resolvedCommands {
            guard let layer = AnnotationLayerFactory.makeLayer(
                for: command,
                contentsScale: scale,
                context: context
            ) else {
                continue
            }
            annotationLayer.addSublayer(layer)
            layers[command.id] = layer
        }
        updateSelectionHandles()
        updateCropOverlay()
        rebuildReviewLayers()
        // The layers just rebuilt sit on the canvas, but the offscreen path covers them
        // with a flattened render — so with a camera or a progressive blur active, a newly
        // drawn annotation was invisible until something else happened to trigger a chrome
        // pass (docs/10 R1.5). Rebuilding the layers *is* a document change, so it is the
        // right place to say the render is stale.
        updateExpensiveChrome()
        lastSyncKey = currentSyncKey
        onDocumentChanged?()
    }

    /// Dashed candidate chrome. Not a command — accepting is what writes a redaction.
    func rebuildReviewLayers() {
        reviewLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let size = model.document.baseImage.size
        for candidate in model.redactionCandidates {
            let shape = CAShapeLayer()
            let rect = candidate.rect(in: size)
            shape.path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            shape.fillColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
            shape.strokeColor = NSColor.systemOrange.cgColor
            shape.lineWidth = 1.5
            shape.lineDashPattern = [5, 3]
            reviewLayer.addSublayer(shape)
        }
    }

    // MARK: - Mouse

    override public func mouseDown(with event: NSEvent) {
        if textEditor.isEditing {
            textEditor.finish()
        }

        if event.clickCount == 2, beginEditingText(at: imagePoint(from: event)) {
            return
        }

        // A click with the text tool on existing text edits it, rather than stacking
        // another box on top.
        if model.tool == .text, beginEditingText(at: imagePoint(from: event)) {
            return
        }

        if spaceIsDown {
            beginSpacePan(with: event)
            return
        }

        window?.makeFirstResponder(self)
        prepareEdgesIfMeasuring()
        let commandsBefore = model.document.commands
        let wasInSync = lastSyncKey == currentSyncKey
        model.pointerDown(
            at: imagePoint(from: event),
            modifiers: modifiers(from: event),
            grabbing: screenSpaceHandle(at: event),
            cropGrabbing: screenSpaceCropHandle(at: event),
            handleTolerance: SelectionResizer.hitRadius / handleViewScale
        )
        refreshAfterPointerDown(commandsBefore: commandsBefore, wasInSync: wasInSync)
    }

    /// A click usually only changes the selection, and then only the handles need
    /// redrawing — not every annotation layer, which is what a rebuild re-rasterised.
    ///
    /// The command comparison is cheap in that case: an untouched list is the same buffer,
    /// and `Array ==` checks that before it compares a single element.
    private func refreshAfterPointerDown(commandsBefore: [AnnotationCommand], wasInSync: Bool) {
        let key = currentSyncKey
        guard wasInSync,
              key.tool == lastSyncKey?.tool,
              key.candidates == lastSyncKey?.candidates,
              model.document.commands == commandsBefore
        else {
            documentChangedExternally()
            return
        }
        lastSyncKey = key
        updateSelectionHandles()
        updateBindingHint()
        window?.invalidateCursorRects(for: self)
    }

    override public func mouseDragged(with event: NSEvent) {
        if continueSpacePan(with: event) {
            return
        }
        let interval = signposter.beginInterval("editor.drag")
        defer { signposter.endInterval("editor.drag", interval) }
        model.pointerDragged(to: imagePoint(from: event), modifiers: modifiers(from: event))
        // The hot path: only the draft and the handles move.
        updateDraftLayer()
        if model.tool == .select || model.isMovingSelection {
            rebuildAnnotationLayersDuringMove()
        }
        if model.tool == .crop {
            updateCropOverlay()
        }
        updateSelectionHandles()
    }

    override public func mouseUp(with event: NSEvent) {
        if endSpacePan() {
            return
        }
        model.pointerUp(at: imagePoint(from: event), modifiers: modifiers(from: event))
        updateDraftLayer()
        updateHighlightPreview()
        // One sync for the whole gesture. It updates the layers in place and falls back to a
        // rebuild only when something was added or removed — a drag used to rebuild (and
        // re-rasterise) every layer here, and again from the SwiftUI update after it.
        documentChangedExternally()
        if let id = model.consumePendingTextEdit() {
            beginEditingText(id)
        }
    }

    /// Reads the base image's edges the first time the measure tool is used.
    ///
    /// Lazy on purpose: it is one pass over every pixel of the capture, and a session that
    /// never measures anything should never pay for it.
    /// The base image's pixels per point, which the measurement readout needs.
    var imageScale: CGFloat {
        model.document.baseImage.scale
    }

    private func prepareEdgesIfMeasuring() {
        guard model.tool == .measure, model.edgeCandidates.isEmpty else { return }
        model.loadEdgesInBackground(from: baseImage)
    }

    /// While dragging a selection, update the moved layers in place rather than rebuilding
    /// the tree — the whole point of keeping a layer per annotation.
    private func rebuildAnnotationLayersDuringMove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let moving = model.layersNeedingUpdateDuringMove
        let context = layerContext(canvasRect: model.document.canvasRect, isLive: true)
        for command in model.document.resolvedCommands where moving.contains(command.id) {
            guard let layer = layers[command.id] else { continue }
            AnnotationLayerFactory.update(layer, for: command, context: context)
        }
        updateCompositeSpotlight()
        updateBindingHint()
    }

    /// Existing layers, in the order they sit on `annotationLayer`.
    private var orderedLayerIDs: [AnnotationID] {
        (annotationLayer.sublayers ?? []).compactMap { layer in
            guard let name = layer.name, let uuid = UUID(uuidString: name) else { return nil }
            return AnnotationID(uuid)
        }
    }

    /// Same IDs in the same order as the document's drawable commands, each with a layer.
    func canUpdateLayersInPlace(for commands: [AnnotationCommand]) -> Bool {
        let drawableIDs = commands.filter { !$0.tool.isCanvasChrome }.map(\.id)
        guard drawableIDs.allSatisfy({ layers[$0] != nil }) else { return false }
        guard layers.count == drawableIDs.count else { return false }
        return drawableIDs == orderedLayerIDs
    }

    func modifiers(from event: NSEvent) -> EditorModifiers {
        var modifiers: EditorModifiers = []
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.constrain)
        }
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.fromCenter)
        }
        if event.modifierFlags.contains(.command) {
            modifiers.insert(.extendSelection)
        }
        return modifiers
    }

    /// After a keyboard edit or undo: the same sync every other document change gets.
    func refreshAfterEdit() {
        documentChangedExternally()
    }

    /// Re-composites the base layer when background removal is applied or undone
    /// (docs/06 M23).
    ///
    /// Cached against the spec that produced it: the composite is a full-image CoreImage
    /// pass, and redoing it on every mouse-up while the user draws arrows over a cut-out
    /// would be visible.
    func refreshBaseImage() {
        let spec = model.document.subjectLift
        guard spec != liftedFrom else { return }
        liftedFrom = spec
        displayedImage = spec.map { subjectLift.apply($0, to: baseImage) } ?? baseImage
        baseLayer.contents = displayedImage
        // Previews of the old pixels are wrong now; the old source takes them with it.
        redactionSource = RedactionPreviewSource(image: displayedImage, scale: imageScale)
        observeRedactionPreviews()
    }
}

/// The document state a canvas layer tree reflects (see `AnnotationCanvasView.currentSyncKey`).
struct CanvasSyncKey: Equatable {
    var revision: UInt64
    var candidates: [RedactionCandidate]
    var tool: EditorTool
}
