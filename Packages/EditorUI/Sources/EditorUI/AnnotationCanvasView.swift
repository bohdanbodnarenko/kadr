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
    private let model: EditorDocumentModel
    private let backdropLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let shadowLayer = CALayer()
    private let contentHost = CALayer()
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
        root.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        backdropLayer.addSublayer(gradientLayer)
        root.addSublayer(backdropLayer)
        root.addSublayer(shadowLayer)

        baseLayer.contents = baseImage
        baseLayer.magnificationFilter = .trilinear
        contentHost.addSublayer(baseLayer)
        for layer in [annotationLayer, draftLayer, selectionLayer] {
            contentHost.addSublayer(layer)
        }
        root.addSublayer(contentHost)

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

    /// Sizes the view and the card so beautify chrome matches export (docs/03 §3 P2).
    private func layoutCanvasChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let imageBounds = model.document.baseImage.bounds
        let content = model.document.contentRect

        guard let spec = model.document.beautify, let layout = model.document.beautifyLayout else {
            setFrameSize(imageBounds.size)
            backdropLayer.isHidden = true
            shadowLayer.isHidden = true
            contentHost.frame = bounds
            contentHost.cornerRadius = 0
            contentHost.masksToBounds = false
            let drawing = CGRect(origin: .zero, size: imageBounds.size)
            baseLayer.frame = drawing
            annotationLayer.frame = drawing
            draftLayer.frame = drawing
            selectionLayer.frame = drawing
            return
        }

        setFrameSize(layout.canvasSize)
        backdropLayer.isHidden = false
        backdropLayer.frame = bounds
        applyBackdrop(spec.backdrop)

        let radius = min(
            spec.cornerRadius,
            min(layout.contentRect.width, layout.contentRect.height) / 2
        )

        shadowLayer.isHidden = !spec.shadow.isEnabled
        shadowLayer.frame = layout.contentRect
        shadowLayer.cornerRadius = radius
        shadowLayer.backgroundColor = NSColor.white.cgColor
        shadowLayer.shadowOpacity = Float(spec.shadow.opacity)
        shadowLayer.shadowRadius = spec.shadow.blur * 0.5
        shadowLayer.shadowOffset = CGSize(width: 0, height: spec.shadow.offsetY)
        shadowLayer.shadowColor = NSColor.black.cgColor

        contentHost.frame = layout.contentRect
        contentHost.cornerRadius = radius
        contentHost.masksToBounds = true

        let drawing = CGRect(
            x: -content.minX,
            y: -content.minY,
            width: imageBounds.width,
            height: imageBounds.height
        )
        baseLayer.frame = drawing
        annotationLayer.frame = drawing
        draftLayer.frame = drawing
        selectionLayer.frame = drawing
    }

    private func applyBackdrop(_ backdrop: BeautifyBackdrop) {
        gradientLayer.isHidden = true
        backdropLayer.contents = nil
        switch backdrop {
        case let .solid(colour):
            backdropLayer.backgroundColor = NSColor(
                srgbRed: colour.red,
                green: colour.green,
                blue: colour.blue,
                alpha: colour.alpha
            ).cgColor
        case let .gradient(start, end, _):
            backdropLayer.backgroundColor = nil
            gradientLayer.isHidden = false
            gradientLayer.frame = backdropLayer.bounds
            gradientLayer.colors = [
                NSColor(srgbRed: start.red, green: start.green, blue: start.blue, alpha: start.alpha).cgColor,
                NSColor(srgbRed: end.red, green: end.green, blue: end.blue, alpha: end.alpha).cgColor
            ]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        case let .image(path):
            backdropLayer.backgroundColor = NSColor.darkGray.cgColor
            if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
                backdropLayer.contents = CGImageSourceCreateImageAtIndex(source, 0, nil)
                backdropLayer.contentsGravity = .resizeAspectFill
            }
        }
    }

    /// Maps a click on the view onto image-space points (beautify offsets the card).
    private func imagePoint(from event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard model.document.beautify != nil, let layout = model.document.beautifyLayout else {
            return viewPoint
        }
        let content = model.document.contentRect
        return CGPoint(
            x: viewPoint.x - layout.contentRect.minX + content.minX,
            y: viewPoint.y - layout.contentRect.minY + content.minY
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
        model.pointerDown(at: imagePoint(from: event), modifiers: modifiers(from: event))
        refreshAfterEdit()
    }

    override public func mouseDragged(with event: NSEvent) {
        model.pointerDragged(to: imagePoint(from: event), modifiers: modifiers(from: event))
        // The hot path: only the draft and the handles move.
        updateDraftLayer()
        if model.tool == .select {
            rebuildAnnotationLayersDuringMove()
        }
        updateSelectionHandles()
    }

    override public func mouseUp(with event: NSEvent) {
        model.pointerUp(at: imagePoint(from: event), modifiers: modifiers(from: event))
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
        layoutCanvasChrome()
        rebuildAnnotationLayers()
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .select ? .arrow : .crosshair)
    }
}
