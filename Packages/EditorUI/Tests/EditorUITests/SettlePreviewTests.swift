import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Cheap while you drag, exact when you stop (docs/09 U1.3).
///
/// The behaviour worth pinning is the one that makes the pattern worth having: a run of
/// changes costs *one* expensive render, not one per change. Everything else follows.
@MainActor
@Suite("Settle preview")
struct SettlePreviewTests {
    /// A counter the settle callback increments, so "how many real renders happened" is a
    /// number rather than a guess.
    private final class Counter {
        /// Not named `count`: the lint rule that steers `count == 0` towards `isEmpty` is
        /// right about collections and wrong about a tally of renders.
        var renders = 0
    }

    /// Waits for something to become true, rather than sleeping for a guess.
    ///
    /// The settle window is tens of milliseconds and these suites run in parallel with a
    /// dozen others, so a fixed `sleep` of four times the window is not the safety margin
    /// it looks like — this suite failed on exactly that, asserting a 30 ms timer had fired
    /// after 120 ms on a machine that had not got round to it. Polling turns "long enough,
    /// probably" into "as long as it takes, up to five seconds", which is both faster in the
    /// ordinary case and not a coin toss in the bad one.
    private func waitUntil(
        _ condition: () -> Bool,
        within timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // A stalled main thread can outlast the deadline; give the queued settle task its
        // turn before deciding (StudioPlaybackFixtures.graceCheck says why).
        return await (try? StudioPlaybackFixtures.graceCheck(condition)) ?? condition()
    }

    @Test("A burst of changes costs exactly one render")
    func burstCollapses() async {
        let counter = Counter()
        let preview = SettlePreview(settleMilliseconds: 30) { counter.renders += 1 }

        for _ in 0 ..< 50 {
            preview.touch()
        }
        #expect(counter.renders == 0, "nothing should render while the value is moving")

        #expect(await waitUntil { counter.renders == 1 })
        #expect(counter.renders == 1)
    }

    @Test("It reports that it is settling, so a view can show the cheap version")
    func reportsSettling() async {
        let preview = SettlePreview(settleMilliseconds: 30) {}
        #expect(!preview.isSettling)

        preview.touch()
        #expect(preview.isSettling)

        #expect(await waitUntil { !preview.isSettling })
    }

    /// A change during the settle window restarts the countdown — otherwise a slow drag
    /// would render mid-gesture and stutter.
    @Test("A change during the wait restarts the countdown")
    func changeRestartsTheCountdown() async {
        let counter = Counter()
        // A wide window on purpose. This is a *negative* assertion — nothing has rendered
        // yet — so unlike the others it cannot be waited for, and its only protection is
        // that the pauses are short relative to the window. At 60 ms with 30 ms pauses a
        // single scheduling hiccup fires the render and fails the test; at 400 with 100 it
        // would take a 300 ms stall.
        let preview = SettlePreview(settleMilliseconds: 400) { counter.renders += 1 }

        preview.touch()
        try? await Task.sleep(for: .milliseconds(100))
        preview.touch()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(counter.renders == 0, "the second change should have pushed the render back")

        #expect(await waitUntil { counter.renders == 1 })
    }

    @Test("Settling now skips the wait, for a caller that knows the drag ended")
    func settleNow() {
        let counter = Counter()
        let preview = SettlePreview(settleMilliseconds: 5000) { counter.renders += 1 }

        preview.touch()
        preview.settleNow()
        #expect(counter.renders == 1)
        #expect(!preview.isSettling)
    }

    @Test("Cancelling abandons the pending render")
    func cancelling() async {
        let counter = Counter()
        let preview = SettlePreview(settleMilliseconds: 30) { counter.renders += 1 }

        preview.touch()
        preview.cancel()
        #expect(!preview.isSettling)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(counter.renders == 0)
    }

    @Test("Two separate gestures are two renders")
    func separateGestures() async {
        let counter = Counter()
        let preview = SettlePreview(settleMilliseconds: 30) { counter.renders += 1 }

        preview.touch()
        #expect(await waitUntil { counter.renders == 1 })
        preview.touch()
        #expect(await waitUntil { counter.renders == 2 })
    }

    /// A preview that goes away mid-gesture must not fire its callback afterwards, and
    /// must not crash cancelling from whatever thread released it.
    @Test("A discarded preview does not fire")
    func discardedPreviewIsSilent() async {
        let counter = Counter()
        do {
            let preview = SettlePreview(settleMilliseconds: 30) { counter.renders += 1 }
            preview.touch()
        }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(counter.renders == 0)
    }
}

/// The progressive blur as the editor sees it (docs/09 U1.3).
@MainActor
@Suite("Editor progressive blur")
struct EditorProgressiveBlurTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    @Test("Turning it on is one undo step")
    func enablingIsOneStep() {
        let model = makeModel()
        model.applyProgressiveBlur(.focus)
        #expect(model.document.progressiveBlur != nil)

        model.undo()
        #expect(model.document.progressiveBlur == nil)
    }

    @Test("A slider drag collapses into one undo step")
    func draggingCoalesces() {
        let model = makeModel()
        model.applyProgressiveBlur(.focus)
        for value in stride(from: 0.02, through: 0.2, by: 0.005) {
            model.applyProgressiveBlur(ProgressiveBlurSpec(radius: .relative(value)))
        }
        #expect(model.document.progressiveBlur != nil)

        model.undo()
        #expect(model.document.progressiveBlur == nil, "the whole drag should be one step")
    }

    @Test("A blur with no strength is not stored at all")
    func identityIsNotStored() {
        let model = makeModel()
        model.applyProgressiveBlur(ProgressiveBlurSpec(radius: .zero))
        #expect(model.document.progressiveBlur == nil)
    }

    @Test("The blur keeps its identity across edits")
    func identityIsStable() {
        let model = makeModel()
        model.applyProgressiveBlur(.focus)
        let first = model.document.progressiveBlur?.id
        model.applyProgressiveBlur(.fade)
        #expect(model.document.progressiveBlur?.id == first)
    }

    @Test("A blur survives a document round trip")
    func roundTrips() throws {
        let model = makeModel()
        model.applyProgressiveBlur(.obscureCentre)

        let data = try JSONEncoder().encode(model.document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded.progressiveBlur?.isInverted == true)
    }

    /// The decorative blur and the redaction blur are separate commands with separate
    /// tools, so neither inspector can reach the other's pixels.
    @Test("It is canvas chrome, never a selectable annotation")
    func isCanvasChrome() {
        let model = makeModel()
        model.applyProgressiveBlur(.focus)
        model.selectAll()
        #expect(model.selection.isEmpty)
    }
}

/// The watermark as the editor sees it (docs/09 U1.4).
@MainActor
@Suite("Editor watermark")
struct EditorWatermarkTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    @Test("Adding a watermark is one undo step")
    func addingIsOneStep() {
        let model = makeModel()
        model.applyWatermark(.signature("Kadr"))
        #expect(model.document.watermark != nil)

        model.undo()
        #expect(model.document.watermark == nil)
    }

    /// Typing into the text field commits per keystroke; the whole word must still be one
    /// undo step, or backing out of a watermark takes as many presses as it had letters.
    @Test("Typing a word collapses into one undo step")
    func typingCoalesces() {
        let model = makeModel()
        model.applyWatermark(.signature("C"))
        for text in ["Co", "Con", "Conf", "Confi", "Confid", "Confide", "Confiden", "Confidential"] {
            model.applyWatermark(.signature(text))
        }
        #expect(model.document.watermark?.text == "Confidential")

        model.undo()
        #expect(model.document.watermark == nil)
    }

    @Test("An empty watermark is not stored at all")
    func emptyIsNotStored() {
        let model = makeModel()
        model.applyWatermark(WatermarkSpec(text: "   "))
        #expect(model.document.watermark == nil)
    }

    @Test("A watermark is canvas chrome, never selectable")
    func isCanvasChrome() {
        let model = makeModel()
        model.applyWatermark(.tiled("Kadr"))
        model.selectAll()
        #expect(model.selection.isEmpty)
    }

    @Test("A watermark survives a document round trip")
    func roundTrips() throws {
        let model = makeModel()
        model.applyWatermark(.tiled("Kadr"))

        let data = try JSONEncoder().encode(model.document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded.watermark?.text == "Kadr")
        #expect(decoded.watermark?.isTiled == true)
    }

    /// A border is part of the beautify card, so it undoes with the rest of the chrome
    /// rather than as its own thing.
    @Test("A border is edited through beautify")
    func borderIsPartOfBeautify() {
        let model = makeModel()
        model.applyBeautify(BeautifySpec(shadow: .none))
        model.applyBeautify(BeautifySpec(shadow: .none, border: .mount))
        #expect(model.document.beautify?.border == .mount)

        model.undo()
        #expect(model.document.beautify == nil, "the whole chrome edit is one step")
    }
}

/// The offscreen chrome path, and what it hides (docs/10 R1.5).
@MainActor
@Suite("Expensive chrome")
struct ExpensiveChromeTests {
    private func canvas(withCamera: Bool) throws -> AnnotationCanvasView {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2)
        ))
        if withCamera {
            // A camera is one of the two things that force the offscreen render path.
            model.applyCamera(AnnotationCameraSpec(tiltDegrees: 20, orbitDegrees: -10, rollDegrees: 0))
        }
        return try AnnotationCanvasView(model: model, baseImage: Self.image())
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 400,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 400 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    /// Without a camera or a blur there is no offscreen render, so the ordinary layer tree
    /// stays visible and nothing is hidden.
    @Test("A plain canvas shows its layers directly")
    func plainCanvasShowsLayers() throws {
        let view = try canvas(withCamera: false)
        view.rebuildAnnotationLayers()
        #expect(!view.contentHost.isHidden)
    }

    @Test("Drawing layers sit on the canvas, not inside the card")
    func annotationsAreNotClippedToTheCard() throws {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2)
        ))
        model.applyBeautify(BeautifySpec(padding: .points(40), shadow: .none, aspect: .original))
        let view = try AnnotationCanvasView(model: model, baseImage: Self.image())
        view.layoutCanvasChrome()

        #expect(view.annotationLayer.superlayer !== view.contentHost)
        #expect(abs(view.annotationLayer.frame.minX - 40) < 0.5)
        #expect(abs(view.annotationLayer.frame.minY - 40) < 0.5)
        #expect(!view.annotationLayer.masksToBounds)
    }

    /// The bug: `contentHost` holds the annotation layers and the offscreen path hides it,
    /// so a newly drawn annotation stayed invisible until something else triggered a
    /// chrome pass. Rebuilding the layers now says the render is stale.
    @Test("Rebuilding the layers marks the offscreen render stale")
    func rebuildTouchesTheChrome() throws {
        let view = try canvas(withCamera: true)
        view.chromeSettle.cancel()
        view.rebuildAnnotationLayers()
        #expect(view.chromeSettle.isSettling, "a redraw left the offscreen render unrefreshed")
    }
}
