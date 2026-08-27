import AnnotationModel
import AnnotationRender
import AppKit
import QuartzCore
import Shared

/// The editor canvas: the capture, the annotations, and the pointer (docs/04 §6).
///
/// A CALayer tree, not SwiftUI. Dragging an annotation on a 5K capture has to hold 60 fps
/// (docs/03 §3), and that means mutating exactly one layer's path per event — no view
/// body re-evaluation, no layout pass, no diffing.
@MainActor
public final class AnnotationCanvasView: NSView {
    private let model: EditorDocumentModel
    private let baseLayer = CALayer()
    private let annotationLayer = CALayer()
    private let draftLayer = CALayer()
    private let selectionLayer = CALayer()
    private let logger = KadrLog.logger(.overlay)

    /// Layers by annotation, so an update finds its own layer without a search.
    private var layers: [AnnotationID: CALayer] = [:]
    private var draftShapeLayer: CALayer?
    private var marqueeLayer = CAShapeLayer()

    /// Called whenever the document changes, so the window can update its title bar.
    public var onDocumentChanged: (() -> Void)?

    public init(model: EditorDocumentModel, baseImage: CGImage) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: model.document.baseImage.size))

        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.textBackgroundColor.cgColor

        baseLayer.contents = baseImage
        baseLayer.frame = model.document.baseImage.bounds
        baseLayer.magnificationFilter = .trilinear
        root.addSublayer(baseLayer)

        for layer in [annotationLayer, draftLayer, selectionLayer] {
            layer.frame = bounds
            root.addSublayer(layer)
        }

        marqueeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marqueeLayer.lineDashPattern = [4, 4]
        selectionLayer.addSublayer(marqueeLayer)

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
        for command in model.document.commands {
            guard let layer = AnnotationLayerFactory.makeLayer(for: command, contentsScale: scale) else {
                continue
            }
            annotationLayer.addSublayer(layer)
            layers[command.id] = layer
        }
        updateSelectionHandles()
        onDocumentChanged?()
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
            AnnotationLayerFactory.update(existing, for: draft)
        } else {
            draftShapeLayer?.removeFromSuperlayer()
            draftShapeLayer = AnnotationLayerFactory.makeLayer(for: draft, contentsScale: scale)
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

        for command in model.document.commands where model.selection.contains(command.id) {
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
        window?.makeFirstResponder(self)
        model.pointerDown(at: convert(event.locationInWindow, from: nil), modifiers: modifiers(from: event))
        refreshAfterEdit()
    }

    override public func mouseDragged(with event: NSEvent) {
        model.pointerDragged(to: convert(event.locationInWindow, from: nil), modifiers: modifiers(from: event))
        // The hot path: only the draft and the handles move.
        updateDraftLayer()
        if model.tool == .select {
            rebuildAnnotationLayersDuringMove()
        }
        updateSelectionHandles()
    }

    override public func mouseUp(with event: NSEvent) {
        model.pointerUp(at: convert(event.locationInWindow, from: nil), modifiers: modifiers(from: event))
        updateDraftLayer()
        rebuildAnnotationLayers()
    }

    /// While dragging a selection, update the moved layers in place rather than rebuilding
    /// the tree — the whole point of keeping a layer per annotation.
    private func rebuildAnnotationLayersDuringMove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for command in model.document.commands where model.selection.contains(command.id) {
            guard let layer = layers[command.id] else { continue }
            AnnotationLayerFactory.update(layer, for: command)
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
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: // Delete, forward delete
            model.deleteSelection()
        case 123: model.nudgeSelection(dx: -step, dy: 0)
        case 124: model.nudgeSelection(dx: step, dy: 0)
        case 125: model.nudgeSelection(dx: 0, dy: step)
        case 126: model.nudgeSelection(dx: 0, dy: -step)
        case 53: model.selection = []
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
            return
        }
        refreshAfterEdit()
    }

    private func refreshAfterEdit() {
        rebuildAnnotationLayers()
    }

    /// Called after undo, redo or an inspector change.
    public func documentChangedExternally() {
        rebuildAnnotationLayers()
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .select ? .arrow : .crosshair)
    }
}
