import AppKit
import Shared
import Testing
@testable import SelectionUI

/// A flat red bitmap, so any sampled pixel has one right answer.
private func redImage() -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: 40,
        height: 40,
        bitsPerComponent: 8,
        bytesPerRow: 40 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    guard let image = context.makeImage() else {
        fatalError("Could not make the test image")
    }
    return image
}

@MainActor
private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ))
}

/// The hint says "Click to copy", so a click has to copy (T-CAP-1).
@MainActor
@Suite("Eyedropper click")
struct EyedropperClickTests {
    private func makeView() -> SelectionOverlayView {
        let view = SelectionOverlayView(
            frozenImage: redImage(),
            bounds: CGRect(x: 0, y: 0, width: 20, height: 20),
            scale: .retina
        )
        view.setEyedropperMode(true)
        return view
    }

    @Test("A click picks the color under the pointer")
    func clickPicks() throws {
        let view = makeView()
        var picks: [ColorPick] = []
        var commits = 0
        view.onPickColor = { picks.append($0) }
        view.onCommit = { _ in commits += 1 }

        try view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        try view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 10, y: 10)))

        #expect(picks.count == 1)
        #expect(picks.first?.text == "#FF0000")
        #expect(commits == 0)
    }

    @Test("A drag while picking never takes a region screenshot")
    func dragDoesNotSelect() throws {
        let view = makeView()
        var commits = 0
        var picks = 0
        view.onCommit = { _ in commits += 1 }
        view.onPickColor = { _ in picks += 1 }

        try view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2)))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 15, y: 15)))
        try view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 15, y: 15)))

        #expect(commits == 0)
        #expect(view.interaction.rect == nil)
        #expect(picks == 1, "the release still picks, where the loupe ended up")
    }

    @Test("Return with nothing drawn takes the last-area ghost (T-CAP-12)")
    func returnTakesGhost() {
        let view = makeView()
        view.setEyedropperMode(false)
        let ghost = CGRect(x: 2, y: 3, width: 10, height: 8)
        view.lastRegionGhost = ghost
        var committed: [CGRect] = []
        view.onCommit = { committed.append($0) }

        view.commitTypedSizeOrSelection()

        #expect(committed == [ghost])
    }

    @Test("Without the eyedropper, a drag commits a region as before")
    func normalDragCommits() throws {
        let view = makeView()
        view.setEyedropperMode(false)
        var commits = 0
        view.onCommit = { _ in commits += 1 }

        try view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2)))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 15, y: 15)))
        try view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 15, y: 15)))

        #expect(commits == 1)
    }
}
