import AnnotationModel
import CoreGraphics
import Foundation
import Shared
import Testing
@testable import EditorUI

/// The measure tool in the editor (docs/03 §3 P3, docs/06 M21).
@MainActor
@Suite("Measure tool")
struct EditorMeasureTests {
    /// A 400 × 300 point capture at 2×, with two vertical and two horizontal lines
    /// standing in for a window's borders.
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2)
        ))
        model.tool = .measure
        return model
    }

    private let candidates = EdgeCandidates(
        // Pixels, so 100 px is 50 pt on this 2× document.
        verticalEdges: [100, 500],
        horizontalEdges: [40, 400],
        pixelSize: PixelSize(width: 800, height: 600)
    )

    @Test("Dragging makes a measurement")
    func dragMeasures() throws {
        let model = makeModel()
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 110, y: 10))
        model.pointerUp(at: CGPoint(x: 110, y: 10))

        let command = try #require(model.document.commands.first)
        guard case let .measure(spec) = command else {
            Issue.record("expected a measurement")
            return
        }
        #expect(spec.length == 100)
        #expect(!spec.measuresBox)
        #expect(spec.readout(scale: 2) == "100 pt · 200 px")
    }

    @Test("A drag that never moved leaves nothing behind when there is nothing to snap to")
    func clickWithoutEdgesDoesNothing() {
        let model = makeModel()
        model.pointerDown(at: CGPoint(x: 50, y: 50))
        model.pointerUp(at: CGPoint(x: 50, y: 50))
        #expect(model.document.commands.isEmpty)
    }

    @Test("Clicking an element measures the box the detected lines put around it")
    func clickMeasuresEnclosingBox() throws {
        let model = makeModel()
        model.edgeCandidates = candidates

        // 150 pt, 100 pt is inside the box bounded by x 100…500 px and y 40…400 px.
        model.pointerDown(at: CGPoint(x: 150, y: 100))
        model.pointerUp(at: CGPoint(x: 150, y: 100))

        let command = try #require(model.document.commands.first)
        guard case let .measure(spec) = command else {
            Issue.record("expected a measurement")
            return
        }
        #expect(spec.measuresBox)
        #expect(spec.rect == CGRect(x: 50, y: 20, width: 200, height: 180))
        #expect(spec.readout(scale: 2) == "200 × 180 pt · 400 × 360 px")
    }

    @Test("Endpoints snap to a nearby detected line")
    func endpointsSnap() throws {
        let model = makeModel()
        model.edgeCandidates = candidates

        // 52 pt is 104 px, four pixels from the line at 100 px — inside the tolerance.
        model.pointerDown(at: CGPoint(x: 52, y: 100))
        model.pointerDragged(to: CGPoint(x: 200, y: 100))
        model.pointerUp(at: CGPoint(x: 200, y: 100))

        let command = try #require(model.document.commands.first)
        guard case let .measure(spec) = command else {
            Issue.record("expected a measurement")
            return
        }
        #expect(spec.start.x == 50)
    }

    @Test("A point far from every line is left alone")
    func farPointsDoNotSnap() {
        let model = makeModel()
        model.edgeCandidates = candidates
        #expect(model.snappedToEdges(CGPoint(x: 200, y: 200)) == CGPoint(x: 200, y: 200))
    }

    @Test("Turning the tolerance to zero turns snapping off")
    func zeroToleranceDisablesSnapping() {
        let model = makeModel()
        model.edgeCandidates = candidates
        model.edgeSnapTolerance = 0
        #expect(model.snappedToEdges(CGPoint(x: 52, y: 100)) == CGPoint(x: 52, y: 100))
    }

    @Test("Only the measure tool snaps, so an arrow lands where it was drawn")
    func otherToolsDoNotSnap() throws {
        let model = makeModel()
        model.edgeCandidates = candidates
        model.tool = .arrow

        model.pointerDown(at: CGPoint(x: 52, y: 100))
        model.pointerDragged(to: CGPoint(x: 200, y: 100))
        model.pointerUp(at: CGPoint(x: 200, y: 100))

        let command = try #require(model.document.commands.first)
        guard case let .arrow(spec) = command else {
            Issue.record("expected an arrow")
            return
        }
        #expect(spec.start.x == 52)
    }

    @Test("The box/distance choice is remembered between measurements")
    func remembersTheChoice() {
        let model = makeModel()
        model.styleMemory.lastMeasuresBox = true

        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 110, y: 60))
        model.pointerUp(at: CGPoint(x: 110, y: 60))

        guard case let .measure(spec) = model.document.commands.first else {
            Issue.record("expected a measurement")
            return
        }
        #expect(spec.measuresBox)
    }

    @Test("A measurement moves with the selection")
    func movesWithSelection() {
        let model = makeModel()
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 110, y: 10))
        model.pointerUp(at: CGPoint(x: 110, y: 10))

        model.selectAll()
        model.nudgeSelection(dx: 5, dy: 7)

        guard case let .measure(spec) = model.document.commands.first else {
            Issue.record("expected a measurement")
            return
        }
        #expect(spec.start == CGPoint(x: 15, y: 17))
        #expect(spec.end == CGPoint(x: 115, y: 17))
    }

    @Test("Reading a base image's edges fills the candidate set")
    func loadEdgesFromImage() throws {
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

        let model = makeModel()
        try model.loadEdges(from: #require(context.makeImage()))
        #expect(!model.edgeCandidates.isEmpty)
        #expect(model.edgeCandidates.verticalEdges.count == 1)
    }
}
