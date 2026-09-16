import AnnotationModel
import AppKit
import CoreGraphics
import Foundation
import Observation
import Testing
@testable import EditorUI

/// What a pointer drag tells the rest of the editor, and when (docs/10 R1).
///
/// A drag rewrites the document on every mouse-moved event. The canvas updates the layers
/// that moved by itself; every other observer — the toolbar, the inspector, the canvas
/// representable — hears about the drag once, when the pointer comes up.
@MainActor
@Suite("Drag publishing")
struct EditorDragPublishingTests {
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.tool = .select
        return model
    }

    @discardableResult
    private func addShape(_ model: EditorDocumentModel) -> AnnotationID {
        let command = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 100, y: 100, width: 60, height: 40),
            fill: FillStyle(color: .white)
        ))
        model.document.add(command)
        return command.id
    }

    /// Counts how often a read of `observe` would have been invalidated while `body` ran.
    private func notifications(
        of observe: @escaping @MainActor () -> Void,
        during body: () -> Void
    ) -> Int {
        let counter = ObservationCounter(observe)
        body()
        return counter.count
    }

    @Test("A drag publishes the document at mouse-up, not per mouse-move")
    func dragPublishesAtMouseUp() {
        let model = makeModel()
        addShape(model)
        model.pointerDown(at: CGPoint(x: 120, y: 120))
        let before = model.documentRevision
        let duringDrag = notifications(of: { _ = model.document }, during: {
            for step in 1 ... 30 {
                model.pointerDragged(to: CGPoint(x: 120 + CGFloat(step), y: 120))
            }
        })
        #expect(duringDrag == 0, "a drag must not publish per mouse-move")
        #expect(model.documentRevision > before, "the drag still edits the document")

        let atMouseUp = notifications(of: { _ = model.document }, during: {
            model.pointerUp(at: CGPoint(x: 150, y: 120))
        })
        #expect(atMouseUp >= 1, "the drag's result has to be published")
        #expect(atMouseUp <= 3, "mouse-up is a handful of publications, not one per event")
    }

    @Test("The moved shape is where the drag left it, and undo still takes it back")
    func dragStillEdits() {
        let model = makeModel()
        let id = addShape(model)
        model.pointerDown(at: CGPoint(x: 120, y: 120))
        for step in 1 ... 10 {
            model.pointerDragged(to: CGPoint(x: 120 + CGFloat(step) * 5, y: 120))
        }
        model.pointerUp(at: CGPoint(x: 170, y: 120))
        guard case let .shape(spec)? = model.document.command(id) else {
            Issue.record("the shape went missing")
            return
        }
        #expect(spec.rect.origin == CGPoint(x: 150, y: 100))

        let undone = notifications(of: { _ = model.document }, during: { model.undo() })
        #expect(undone == 1, "undo is published as it happens")
        guard case let .shape(back)? = model.document.command(id) else {
            Issue.record("the shape went missing")
            return
        }
        #expect(back.rect.origin == CGPoint(x: 100, y: 100))
    }

    @Test("Selection and undo state publish only when they change")
    func derivedStatePublishesOnChange() {
        let model = makeModel()
        let id = addShape(model)
        model.selection = []

        // A style edit that leaves the selection alone is not a selection change.
        model.selection = [id]
        let selectionChanges = notifications(of: { _ = model.selection }, during: {
            model.document.update(.shape(ShapeSpec(
                id: id,
                rect: CGRect(x: 100, y: 100, width: 80, height: 40),
                fill: FillStyle(color: .white)
            )))
            model.selection = [id]
        })
        #expect(selectionChanges == 0)

        let undoChanges = notifications(of: { _ = model.canUndo }, during: {
            // Already undoable; another edit changes nothing about that.
            model.document.update(.shape(ShapeSpec(
                id: id,
                rect: CGRect(x: 100, y: 100, width: 90, height: 40),
                fill: FillStyle(color: .white)
            )))
        })
        #expect(undoChanges == 0)

        let redoChanges = notifications(of: { _ = model.canRedo }, during: { model.undo() })
        #expect(redoChanges == 1)

        let cleared = notifications(of: { _ = model.selection }, during: { model.selection = [] })
        #expect(cleared == 1)
    }

    @Test("Every write bumps the revision, published or not")
    func revisionCounts() {
        let model = makeModel()
        let start = model.documentRevision
        addShape(model)
        #expect(model.documentRevision > start)
        let afterAdd = model.documentRevision
        model.pointerDown(at: CGPoint(x: 120, y: 120))
        model.pointerDragged(to: CGPoint(x: 130, y: 120))
        #expect(model.documentRevision > afterAdd)
        model.pointerUp(at: CGPoint(x: 130, y: 120))
        #expect(!model.isPointerGestureActive)
    }

    @Test("A crop drag keeps the crop size readout live")
    func cropReadoutIsLive() {
        let model = makeModel()
        model.tool = .crop
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        let changes = notifications(of: { _ = model.cropWorkingRect }, during: {
            model.pointerDragged(to: CGPoint(x: 110, y: 60))
            model.pointerDragged(to: CGPoint(x: 210, y: 160))
        })
        #expect(changes >= 2, "the crop bar reads the working rect while the handle moves")
        #expect(model.liveCropRect != nil)
        #expect(model.cropWorkingRect == model.document.crop?.rect, "the readout is the crop being dragged")
        model.pointerUp(at: CGPoint(x: 210, y: 160))
        #expect(model.liveCropRect == nil)
        #expect(model.cropWorkingRect == model.document.crop?.rect)
    }

    @Test("Visible bounds measured after open are adopted once, and are not an edit")
    func lateVisibleBounds() {
        let model = makeModel()
        let rect = CGRect(x: 10, y: 10, width: 700, height: 500)
        model.adoptVisibleBounds(rect)
        #expect(model.document.baseImage.visibleBounds == rect)
        #expect(!model.hasUnsavedChanges)
        #expect(!model.canUndo)

        model.adoptVisibleBounds(CGRect(x: 20, y: 20, width: 600, height: 400))
        #expect(model.document.baseImage.visibleBounds == rect, "a measured capture keeps its measurement")
    }

    @Test("Edges load off the main actor and land in the model")
    func edgesLoadInBackground() async throws {
        let context = try #require(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 60, y: 0, width: 1, height: 100))
        let image = try #require(context.makeImage())

        let model = makeModel()
        model.loadEdgesInBackground(from: image)
        #expect(model.edgeCandidates.isEmpty, "nothing is detected inline")
        for _ in 0 ..< 200 where model.edgeCandidates.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.edgeCandidates.verticalEdges.count == 1)
    }
}

/// The canvas's side of the same contract.
@MainActor
@Suite("Canvas sync")
struct CanvasSyncTests {
    private struct Fixture {
        let view: AnnotationCanvasView
        let model: EditorDocumentModel
        let shape: AnnotationID
    }

    private func makeCanvas() throws -> Fixture {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2)
        ))
        model.tool = .select
        let command = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 100, y: 100, width: 60, height: 40),
            fill: FillStyle(color: .white)
        ))
        model.document.add(command)
        let context = try #require(CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        return Fixture(view: AnnotationCanvasView(model: model, baseImage: image), model: model, shape: command.id)
    }

    @Test("A selection change updates the layers in place instead of rebuilding them")
    func selectionSyncsInPlace() throws {
        let fixture = try makeCanvas()
        let (view, model, id) = (fixture.view, fixture.model, fixture.shape)
        let layer = try #require(view.layers[id])
        model.selection = [id]
        view.syncWithModelIfNeeded()
        #expect(view.layers[id] === layer)
        #expect(view.lastSyncKey == view.currentSyncKey)
    }

    @Test("An unchanged model does not sync again")
    func unchangedDoesNotSync() throws {
        let view = try makeCanvas().view
        view.syncWithModelIfNeeded()
        let key = view.lastSyncKey
        view.syncWithModelIfNeeded()
        #expect(view.lastSyncKey == key)
    }

    @Test("Mid-drag, the SwiftUI update path leaves the layers to the drag")
    func dragSkipsSync() throws {
        let fixture = try makeCanvas()
        let (view, model) = (fixture.view, fixture.model)
        view.syncWithModelIfNeeded()
        model.pointerDown(at: CGPoint(x: 120, y: 120))
        model.pointerDragged(to: CGPoint(x: 140, y: 120))
        view.syncWithModelIfNeeded()
        #expect(view.lastSyncKey != view.currentSyncKey, "a drag must not trigger a whole-tree sync")

        model.pointerUp(at: CGPoint(x: 140, y: 120))
        view.syncWithModelIfNeeded()
        #expect(view.lastSyncKey == view.currentSyncKey, "mouse-up catches the tree up")
    }

    @Test("Selection handles are reused from update to update")
    func handlesAreReused() throws {
        let fixture = try makeCanvas()
        let (view, model, id) = (fixture.view, fixture.model, fixture.shape)
        model.selection = [id]
        view.updateSelectionHandles()
        let first = view.handleLayers
        #expect(!first.isEmpty)
        view.updateSelectionHandles()
        #expect(view.handleLayers.count == first.count)
        #expect(zip(view.handleLayers, first).allSatisfy { $0 === $1 })

        model.selection = []
        view.updateSelectionHandles()
        let allHidden = view.handleLayers.allSatisfy(\.isHidden)
        #expect(allHidden)
        #expect(view.selectionOutlineLayer.isHidden)
    }
}

/// Re-reads after every change, the way a view does, and counts the changes.
@MainActor
private final class ObservationCounter {
    private(set) var count = 0
    private let observe: @MainActor () -> Void

    init(_ observe: @escaping @MainActor () -> Void) {
        self.observe = observe
        arm()
    }

    private func arm() {
        withObservationTracking {
            observe()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.count += 1
                self?.arm()
            }
        }
    }
}
