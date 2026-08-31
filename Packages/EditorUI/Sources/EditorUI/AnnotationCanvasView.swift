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
            rebuildAnnotationLayers()
        }
        return editor
    }()

    let contentHost = CALayer()
    let baseLayer = CALayer()
    let annotationLayer = CALayer()
    let reviewLayer = CALayer()
    let draftLayer = CALayer()
    let selectionLayer = CALayer()
    private let logger = KadrLog.logger(.overlay)

    /// Layers by annotation, so an update finds its own layer without a search.
    private var layers: [AnnotationID: CALayer] = [:]
    private var draftShapeLayer: CALayer?
    /// Kept so the measure tool can read the image's straight edges the first time it is
    /// used — never at open, because most sessions never measure anything (docs/06 M21).
    let baseImage: CGImage
    private let subjectLift = SubjectLiftCompositor()
    /// The lift the base layer currently shows, so the composite is not redone per edit.
    private var liftedFrom: SubjectLiftSpec?
    private var marqueeLayer = CAShapeLayer()
    /// Space-drag pans the canvas the way a hand tool does in every other image editor.
    var spaceIsDown = false
    var spacePanAnchor: CGPoint?
    var spacePanClipOrigin: CGPoint?

    /// Called whenever the document changes, so the window can update its title bar.
    public var onDocumentChanged: (() -> Void)?

    public init(model: EditorDocumentModel, baseImage: CGImage) {
        self.model = model
        self.baseImage = baseImage
        super.init(frame: CGRect(origin: .zero, size: model.document.baseImage.size))

        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor
        root.isOpaque = false

        backdropLayer.addSublayer(gradientLayer)
        root.addSublayer(backdropLayer)
        root.addSublayer(shadowLayer)

        baseLayer.contents = baseImage
        baseLayer.magnificationFilter = .trilinear
        contentHost.addSublayer(baseLayer)
        for layer in [annotationLayer, reviewLayer, draftLayer, selectionLayer] {
            contentHost.addSublayer(layer)
        }
        root.addSublayer(contentHost)
        cameraLayer.isHidden = true
        root.addSublayer(cameraLayer)

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
        // Resolved, so a bound arrow is drawn against its target's current geometry
        // rather than against the endpoint it was stored with (docs/09 U1.7).
        for command in model.document.resolvedCommands {
            guard let layer = AnnotationLayerFactory.makeLayer(
                for: command,
                contentsScale: scale,
                imageScale: imageScale
            ) else {
                continue
            }
            annotationLayer.addSublayer(layer)
            layers[command.id] = layer
        }
        updateSelectionHandles()
        rebuildReviewLayers()
        // The layers just rebuilt live inside `contentHost`, which the offscreen path
        // hides — so with a camera or a progressive blur active, a newly drawn annotation
        // was invisible until something else happened to trigger a chrome pass (docs/10
        // R1.5). Rebuilding the layers *is* a document change, so it is the right place to
        // say the render is stale.
        updateExpensiveChrome()
        onDocumentChanged?()
    }

    /// Dashed candidate chrome. Not a command — accepting is what writes a redaction.
    private func rebuildReviewLayers() {
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

    /// Sizes the view and the card so beautify chrome matches export (docs/03 §3 P2).
    /// Maps a click on the view onto image-space points (beautify offsets the card).
    private func imagePoint(from event: NSEvent) -> CGPoint {
        imagePoint(fromWindowPoint: event.locationInWindow)
    }

    /// The same mapping from a bare window point.
    ///
    /// Internal, not private: a drop reports a location rather than an event, and the
    /// drop handling lives in `AnnotationCanvasView+Drop.swift`.
    func imagePoint(fromWindowPoint windowPoint: CGPoint) -> CGPoint {
        var viewPoint = convert(windowPoint, from: nil)

        // A tilted capture is still editable, because the click is traced back through the
        // camera's inverse before anything else looks at it. Without this, clicking a
        // shape on a leaning screenshot selects whatever sits at the same *screen* point
        // on the upright one (docs/09 U1.2).
        if let camera = model.document.cameraGeometry {
            guard let unprojected = camera.contentPoint(from: viewPoint) else { return viewPoint }
            viewPoint = unprojected
        }

        guard model.document.beautify != nil, let layout = model.document.beautifyLayout else {
            return viewPoint
        }
        let content = model.document.contentRect
        return CGPoint(
            x: viewPoint.x - layout.imageRect.minX + content.minX,
            y: viewPoint.y - layout.imageRect.minY + content.minY
        )
    }

    /// Refreshes the live drag preview: one layer, replaced only when the kind changes.
    private func updateDraftLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let draft = model.draft else {
            draftShapeLayer?.removeFromSuperlayer()
            draftShapeLayer = nil
            return
        }

        let scale = window?.backingScaleFactor ?? 2
        if let existing = draftShapeLayer, existing.name == draft.id.rawValue.uuidString {
            AnnotationLayerFactory.update(existing, for: draft, imageScale: imageScale)
        } else {
            draftShapeLayer?.removeFromSuperlayer()
            draftShapeLayer = AnnotationLayerFactory.makeLayer(for: draft, contentsScale: scale, imageScale: imageScale)
            if let layer = draftShapeLayer {
                draftLayer.addSublayer(layer)
            }
        }
    }

    /// Handles around the selection, and the marquee while one is being dragged.
    private func updateSelectionHandles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        selectionLayer.sublayers?
            .filter { $0 !== marqueeLayer }
            .forEach { $0.removeFromSuperlayer() }

        for command in model.document.resolvedCommands where model.selection.contains(command.id) {
            let box = AnnotationHitTesting.boundingBox(of: command).insetBy(dx: -4, dy: -4)
            let outline = CAShapeLayer()
            outline.path = CGPath(rect: box, transform: nil)
            outline.strokeColor = NSColor.controlAccentColor.cgColor
            outline.fillColor = nil
            outline.lineWidth = 1
            outline.lineDashPattern = [3, 3]
            selectionLayer.addSublayer(outline)

            for corner in [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)
            ] {
                let handle = CALayer()
                handle.frame = CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6)
                handle.backgroundColor = NSColor.white.cgColor
                handle.borderColor = NSColor.controlAccentColor.cgColor
                handle.borderWidth = 1
                handle.cornerRadius = 1
                selectionLayer.addSublayer(handle)
            }
        }

        marqueeLayer.path = model.marquee.map { CGPath(rect: $0, transform: nil) }
    }

    // MARK: - Mouse

    override public func mouseDown(with event: NSEvent) {
        if textEditor.isEditing {
            textEditor.finish()
        }

        if event.clickCount == 2, beginEditingText(at: imagePoint(from: event)) {
            return
        }

        if spaceIsDown {
            beginSpacePan(with: event)
            return
        }

        window?.makeFirstResponder(self)
        prepareEdgesIfMeasuring()
        model.pointerDown(at: imagePoint(from: event), modifiers: modifiers(from: event))
        refreshAfterEdit()
    }

    override public func mouseDragged(with event: NSEvent) {
        if continueSpacePan(with: event) {
            return
        }
        model.pointerDragged(to: imagePoint(from: event), modifiers: modifiers(from: event))
        // The hot path: only the draft and the handles move.
        updateDraftLayer()
        if model.tool == .select {
            rebuildAnnotationLayersDuringMove()
        }
        updateSelectionHandles()
    }

    override public func mouseUp(with event: NSEvent) {
        if endSpacePan() {
            return
        }
        model.pointerUp(at: imagePoint(from: event), modifiers: modifiers(from: event))
        updateDraftLayer()
        rebuildAnnotationLayers()
    }

    /// Opens the in-place editor over the text annotation under `point`, if there is one.
    private func beginEditingText(at point: CGPoint) -> Bool {
        let candidates = model.document.commands.filter { $0.tool == .text }
        guard let hit = AnnotationHitTesting.topmost(in: candidates, at: point),
              case let .text(spec) = hit
        else {
            return false
        }

        model.document.selection = [spec.id]
        textEditor.begin(editing: spec, in: self)
        // The annotation is drawn by the field while it is being edited; drawing it
        // underneath as well would double every glyph.
        layers[spec.id]?.isHidden = true
        return true
    }

    /// Reads the base image's edges the first time the measure tool is used.
    ///
    /// Lazy on purpose: it is one pass over every pixel of the capture, and a session that
    /// never measures anything should never pay for it.
    /// The base image's pixels per point, which the measurement readout needs.
    private var imageScale: CGFloat {
        model.document.baseImage.scale
    }

    private func prepareEdgesIfMeasuring() {
        guard model.tool == .measure, model.edgeCandidates.isEmpty else { return }
        model.loadEdges(from: baseImage)
    }

    /// While dragging a selection, update the moved layers in place rather than rebuilding
    /// the tree — the whole point of keeping a layer per annotation.
    private func rebuildAnnotationLayersDuringMove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for command in model.document.resolvedCommands where model.selection.contains(command.id) {
            guard let layer = layers[command.id] else { continue }
            AnnotationLayerFactory.update(layer, for: command, imageScale: imageScale)
        }
    }

    private func modifiers(from event: NSEvent) -> EditorModifiers {
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

    // MARK: - Keyboard

    override public func keyDown(with event: NSEvent) {
        if event.isARepeat, event.keyCode == 49 {
            return
        }
        if event.keyCode == 49, !event.modifierFlags.contains(.command) {
            spaceIsDown = true
            window?.invalidateCursorRects(for: self)
            return
        }

        let command = event.modifierFlags.contains(.command)
        if command {
            super.keyDown(with: event)
            return
        }

        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: // Delete, forward delete
            model.deleteSelection()
        case 123: model.nudgeSelection(dx: -step, dy: 0)
        case 124: model.nudgeSelection(dx: step, dy: 0)
        case 125: model.nudgeSelection(dx: 0, dy: step)
        case 126: model.nudgeSelection(dx: 0, dy: -step)
        case 53: // Escape
            if model.tool != .select {
                model.tool = .select
            } else {
                model.selection = []
            }
        default:
            // A bare letter picks a tool (docs/03 §3).
            guard !event.modifierFlags.contains(.command),
                  let character = event.charactersIgnoringModifiers?.lowercased().first,
                  let tool = EditorTool.allCases.first(where: { $0.shortcut == character })
            else {
                super.keyDown(with: event)
                return
            }
            model.tool = tool
            window?.invalidateCursorRects(for: self)
            return
        }
        refreshAfterEdit()
    }

    override public func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = false
            endSpacePan()
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyUp(with: event)
    }

    private func refreshAfterEdit() {
        refreshBaseImage()
        rebuildAnnotationLayers()
    }

    /// Re-composites the base layer when background removal is applied or undone
    /// (docs/06 M23).
    ///
    /// Cached against the spec that produced it: the composite is a full-image CoreImage
    /// pass, and redoing it on every mouse-up while the user draws arrows over a cut-out
    /// would be visible.
    private func refreshBaseImage() {
        let spec = model.document.subjectLift
        guard spec != liftedFrom else { return }
        liftedFrom = spec
        baseLayer.contents = spec.map { subjectLift.apply($0, to: baseImage) } ?? baseImage
    }

    /// Called after undo, redo or an inspector change.
    public func documentChangedExternally() {
        layoutCanvasChrome()
        refreshBaseImage()
        rebuildAnnotationLayers()
        window?.invalidateCursorRects(for: self)
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: canvasCursor)
    }

    private var canvasCursor: NSCursor {
        if spaceIsDown {
            return spacePanAnchor == nil ? NSCursor.openHand : NSCursor.closedHand
        }
        switch model.tool {
        case .select:
            return NSCursor.arrow
        case .text:
            return NSCursor.iBeam
        case .crop:
            return NSCursor.crosshair
        default:
            return NSCursor.crosshair
        }
    }
}
