import AnnotationModel
import AnnotationRender
import AppKit
import QuartzCore

/// Keeping the layer tree in step with the document, and redaction previews that arrive
/// from off the main actor (docs/10 R1).
extension AnnotationCanvasView {
    // MARK: - Redaction previews

    /// What the layer factory needs from this canvas, for a drag (`isLive`) or not.
    func layerContext(canvasRect: CGRect, isLive: Bool) -> AnnotationLayerContext {
        AnnotationLayerContext(
            imageScale: imageScale,
            baseImage: displayedImage,
            canvasRect: canvasRect,
            redaction: RedactionPreviewContext(source: redactionSource, isLive: isLive)
        )
    }

    func observeRedactionPreviews() {
        redactionSource.onPreviewReady = { [weak self] in
            self?.redactionPreviewsDidUpdate()
        }
    }

    /// A preview finished off the main actor: put it on whichever redaction layers want it.
    private func redactionPreviewsDidUpdate() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let isDragging = model.isPointerGestureActive
        let moving = isDragging ? model.layersNeedingUpdateDuringMove : []
        let canvasRect = model.document.canvasRect
        for command in model.document.resolvedCommands {
            guard case .redaction = command, let layer = layers[command.id] else { continue }
            AnnotationLayerFactory.update(
                layer,
                for: command,
                context: layerContext(canvasRect: canvasRect, isLive: moving.contains(command.id))
            )
        }
        if let draft = model.draft, case .redaction = draft, let layer = draftShapeLayer {
            AnnotationLayerFactory.update(
                layer,
                for: draft,
                context: layerContext(canvasRect: canvasRect, isLive: true)
            )
        }
    }

    // MARK: - Sync

    /// What the layer tree reflects. Inspector style memory is not in here, so picking a
    /// colour for the *next* stroke does not touch the layers already on screen.
    var currentSyncKey: CanvasSyncKey {
        CanvasSyncKey(
            revision: model.documentRevision,
            candidates: model.redactionCandidates,
            tool: model.tool
        )
    }

    /// Brings the layers up to date if the document moved on without them — the SwiftUI
    /// update path.
    ///
    /// Skipped while a pointer drag is open: the drag updates the layers it moves itself,
    /// and mouse-up syncs once. Syncing here as well was a second, whole-tree update per
    /// mouse-move (docs/10 R1).
    public func syncWithModelIfNeeded() {
        // Read through the observed accessor, so the representable calling this is
        // re-run whenever the document is published.
        _ = model.document.selection
        let key = currentSyncKey
        guard !model.isPointerGestureActive, key != lastSyncKey else { return }
        documentChangedExternally()
    }

    /// Called after undo, redo or an inspector change.
    public func documentChangedExternally() {
        lastSyncKey = currentSyncKey
        layoutCanvasChromeIfNeeded()
        refreshBaseImage()
        syncAnnotationLayers()
        window?.invalidateCursorRects(for: self)
    }

    /// Relays the card only when its geometry actually moved — a stroke-width tick
    /// must not re-lay wallpaper, shadows and the offscreen chrome.
    private func layoutCanvasChromeIfNeeded() {
        let key = canvasLayoutKey()
        guard lastLayoutKey != key else { return }
        lastLayoutKey = key
        layoutCanvasChrome()
    }

    /// Style and geometry edits update the layers that are already on screen. Adding,
    /// deleting or reordering still rebuilds the tree.
    private func syncAnnotationLayers() {
        let commands = model.document.resolvedCommands
        guard canUpdateLayersInPlace(for: commands) else {
            rebuildAnnotationLayers()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let context = layerContext(canvasRect: model.document.canvasRect, isLive: false)
        for command in commands {
            guard let layer = layers[command.id] else { continue }
            AnnotationLayerFactory.update(layer, for: command, context: context)
        }
        updateSelectionHandles()
        updateCropOverlay()
        rebuildReviewLayers()
        updateCompositeSpotlight()
        updateWatermarkLayer()
        updateExpensiveChrome()
        onDocumentChanged?()
    }
}
