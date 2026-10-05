import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// The render geometry the preview and the export both build from (docs/09 U3.3).
///
/// All of it is arithmetic, which is the point: the part of a renderer most likely to be
/// subtly wrong — a crop that is off by the crop's own origin, a magnification applied
/// twice — is the part that never needs a video file to test.
@Suite("Studio render plan")
struct StudioRenderPlanTests {
    private let size = CGSize(width: 1920, height: 1080)

    private func edit(
        zooms: [ZoomCue] = [],
        reframe: Reframe = .original,
        duration: TimeInterval = 10
    ) -> StudioEdit {
        var edit = StudioEdit.untouched(duration: duration)
        edit.zooms = zooms
        edit.reframe = reframe
        return edit
    }

    // MARK: - The untouched case

    @Test("An untouched edit renders the whole frame at its own size")
    func untouched() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: size)
        #expect(plan.outputSize == size)
        #expect(plan.crop == CGRect(origin: .zero, size: size))
        #expect(plan.sourceRect(at: 0) == CGRect(origin: .zero, size: size))
        #expect(plan.scale(at: 0) == 1)
    }

    @Test("A free crop shrinks the source before the aspect reframe")
    func freeCrop() {
        var cropped = edit()
        cropped.cropRect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let plan = StudioRenderPlan(edit: cropped, sourceSize: size)
        #expect(abs(plan.crop.minX - size.width * 0.25) < 0.001)
        #expect(abs(plan.crop.width - size.width * 0.5) < 0.001)
        #expect(plan.outputSize.width <= size.width * 0.5 + 1)
    }

    @Test("A point maps to itself when nothing is cropped or zoomed")
    func identityMapping() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: size)
        let point = CGPoint(x: 400, y: 300)
        let mapped = plan.outputPoint(point, at: 0)
        #expect(abs(mapped.x - point.x) < 0.001)
        #expect(abs(mapped.y - point.y) < 0.001)
    }

    // MARK: - Even dimensions

    /// An odd dimension is either refused by the encoder or padded with a green column
    /// that survives into the file, so the output is always rounded to even.
    @Test(
        "Output dimensions are always even",
        arguments: [
            CGSize(width: 1921, height: 1081),
            CGSize(width: 3, height: 3),
            CGSize(width: 1080, height: 1920)
        ]
    )
    func evenOutput(source: CGSize) {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: source)
        #expect(Int(plan.outputSize.width) % 2 == 0)
        #expect(Int(plan.outputSize.height) % 2 == 0)
        #expect(plan.outputSize.width >= 2)
        #expect(plan.outputSize.height >= 2)
    }

    @Test("Rounding never grows the frame past the source")
    func roundingNeverGrows() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: CGSize(width: 1921, height: 1081))
        #expect(plan.outputSize.width <= 1921)
        #expect(plan.outputSize.height <= 1081)
    }

    // MARK: - Reframe

    @Test("A vertical reframe produces a portrait output")
    func verticalReframe() {
        let plan = StudioRenderPlan(edit: edit(reframe: Reframe(aspect: .nineSixteen)), sourceSize: size)
        let ratio = plan.outputSize.width / plan.outputSize.height
        #expect(abs(ratio - 9.0 / 16.0) < 0.01, "expected 9:16, got \(ratio)")
        #expect(plan.outputSize.height <= size.height)
    }

    @Test("A fill reframe crops rather than showing the whole frame")
    func fillCrops() {
        let plan = StudioRenderPlan(
            edit: edit(reframe: Reframe(aspect: .nineSixteen, fill: .fill)),
            sourceSize: size
        )
        #expect(plan.crop.width < size.width)
        #expect(abs(plan.crop.height - size.height) < 1, "a 9:16 crop of 16:9 keeps the full height")
    }

    /// The correction that matters: a cue's anchor is written against the whole frame, and
    /// after a crop the same numbers mean a different place. Without the translation a
    /// centred zoom drifts to the crop's edge.
    @Test("A centerd zoom stays centerd through a fill reframe")
    func zoomStaysCentredAcrossReframe() {
        let cue = ZoomCue(
            start: 0,
            duration: 8,
            magnification: 2,
            anchor: .fixed(CGPoint(x: size.width / 2, y: size.height / 2))
        )
        let plan = StudioRenderPlan(
            edit: edit(zooms: [cue], reframe: Reframe(aspect: .nineSixteen, fill: .fill, follows: false)),
            sourceSize: size
        )
        // Late enough for the spring to have settled.
        let rect = plan.sourceRect(at: 6)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        #expect(abs(centre.x - size.width / 2) < 20, "drifted to \(center.x)")
        #expect(abs(centre.y - size.height / 2) < 20, "drifted to \(center.y)")
    }

    /// A 9:16 crop of a 16:9 recording is already about three times closer, so applying the
    /// cue's original magnification on top of it would show a handful of pixels.
    @Test("A reframe takes its own zoom out of the cue's magnification")
    func reframeDividesMagnification() {
        let cue = ZoomCue(start: 0, duration: 8, magnification: 2, anchor: .centre)
        let plain = StudioRenderPlan(edit: edit(zooms: [cue]), sourceSize: size)
        let reframed = StudioRenderPlan(
            edit: edit(zooms: [cue], reframe: Reframe(aspect: .nineSixteen, fill: .fill, follows: false)),
            sourceSize: size
        )
        let plainZoom = plain.sourceSize.width / plain.sourceRect(at: 6).width
        let reframedZoom = reframed.crop.width / reframed.sourceRect(at: 6).width
        #expect(reframedZoom < plainZoom, "the reframe's own zoom was not accounted for")
    }

    // MARK: - Zoom

    @Test("A zoom cue narrows the source rect and raises the scale")
    func zoomNarrows() {
        let cue = ZoomCue(start: 0, duration: 8, magnification: 2, anchor: .centre)
        let plan = StudioRenderPlan(edit: edit(zooms: [cue]), sourceSize: size)
        let rect = plan.sourceRect(at: 6)
        #expect(rect.width < size.width * 0.6)
        #expect(plan.scale(at: 6) > 1.7)
    }

    @Test("The source rect never leaves the recording")
    func sourceRectStaysInside() {
        let cue = ZoomCue(
            start: 0,
            duration: 8,
            magnification: 3,
            // Hard against the corner: the clamp is what stops this showing blank frame.
            anchor: .fixed(CGPoint(x: 0, y: 0))
        )
        let plan = StudioRenderPlan(edit: edit(zooms: [cue]), sourceSize: size)
        for step in 0 ... 10 {
            let rect = plan.sourceRect(at: Double(step))
            #expect(rect.minX >= -0.001, "ran off the left at \(step)s")
            #expect(rect.minY >= -0.001, "ran off the top at \(step)s")
            #expect(rect.maxX <= size.width + 0.001, "ran off the right at \(step)s")
            #expect(rect.maxY <= size.height + 0.001, "ran off the bottom at \(step)s")
        }
    }

    /// What the overlays depend on: the anchor of a settled zoom lands in the middle of
    /// the output, so a cursor at that point is drawn in the middle rather than offset by
    /// however much the camera moved.
    @Test("A settled zoom puts its anchor at the center of the output")
    func anchorLandsAtTheCentre() {
        let anchor = CGPoint(x: 700, y: 400)
        let cue = ZoomCue(start: 0, duration: 8, magnification: 2, anchor: .fixed(anchor))
        let plan = StudioRenderPlan(edit: edit(zooms: [cue]), sourceSize: size)
        let mapped = plan.outputPoint(anchor, at: 6)
        #expect(abs(mapped.x - plan.outputSize.width / 2) < 20, "x landed at \(mapped.x)")
        #expect(abs(mapped.y - plan.outputSize.height / 2) < 20, "y landed at \(mapped.y)")
    }

    @Test("Scale and point mapping agree")
    func scaleAgreesWithMapping() {
        let cue = ZoomCue(start: 0, duration: 8, magnification: 2.5, anchor: .centre)
        let plan = StudioRenderPlan(edit: edit(zooms: [cue]), sourceSize: size)
        let scale = plan.scale(at: 6)
        let near = plan.outputPoint(CGPoint(x: 900, y: 500), at: 6)
        let far = plan.outputPoint(CGPoint(x: 1000, y: 500), at: 6)
        #expect(abs((far.x - near.x) - 100 * scale) < 0.5, "a 100px span did not scale by \(scale)")
    }

    // MARK: - Motion

    @Test("The camera is still when nothing is zooming")
    func stillWhenUnzoomed() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: size)
        #expect(!plan.isMoving(at: 5))
    }

    @Test("The camera is moving while a zoom is coming in")
    func movingDuringATransition() {
        let cue = ZoomCue(start: 1, duration: 5, magnification: 2, anchor: .centre)
        let plan = StudioRenderPlan(edit: edit(zooms: [cue]), sourceSize: size)
        #expect(plan.isMoving(at: 1.2), "the spring should still be travelling just after the cue opens")
    }

    // MARK: - Degenerate input

    @Test("A zero-length edit still plans something renderable")
    func zeroDuration() {
        let plan = StudioRenderPlan(edit: edit(duration: 0), sourceSize: size)
        #expect(plan.outputSize.width > 0)
        #expect(plan.sourceRect(at: 0).width > 0)
    }

    @Test("A degenerate source size does not produce a crash or a NaN")
    func degenerateSource() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: .zero)
        #expect(plan.scale(at: 0).isFinite)
        #expect(plan.outputPoint(.zero, at: 0).x.isFinite)
    }

    @Test("Capping the longest edge shrinks a 4K frame to 1080p without changing aspect")
    func longestEdgeCap() {
        let fourK = CGSize(width: 3840, height: 2160)
        let plan = StudioRenderPlan(edit: edit(), sourceSize: fourK, maxLongestEdge: 1920)
        #expect(plan.outputSize.width == 1920)
        #expect(plan.outputSize.height == 1080)
    }

    @Test("A cap larger than the frame leaves it alone")
    func longestEdgeCapIsANoOpWhenAlreadySmaller() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: size, maxLongestEdge: 3840)
        #expect(plan.outputSize == size)
    }

    @Test("A padded canvas keeps the reframe aspect and centers the card")
    func paddedCanvasGrows() {
        var padded = edit()
        padded.canvas = StudioCanvas(paddingFraction: 0.1)
        let plan = StudioRenderPlan(edit: padded, sourceSize: size)
        #expect(plan.outputSize == size)
        #expect(plan.cardRect.width < size.width)
        #expect(abs(plan.cardRect.midX - plan.outputSize.width / 2) < 1)
        #expect(Int(plan.outputSize.width) % 2 == 0)
        #expect(Int(plan.outputSize.height) % 2 == 0)
    }

    /// Smooth vs Dynamic is a camera look, not the pointer's (CleanShot §14.3).
    @Test("A dynamic zoom has arrived further than a smooth one at the same moment")
    func zoomStyleMovesTheCamera() {
        let cue = ZoomCue(start: 0, duration: 2, magnification: 2)
        var smooth = edit(zooms: [cue], duration: 4)
        smooth.zoomStyle = .smooth
        var dynamic = smooth
        dynamic.zoomStyle = .dynamic
        let earlySmooth = StudioRenderPlan(edit: smooth, sourceSize: size)
            .viewports.viewport(at: 0.12).magnification
        let earlyDynamic = StudioRenderPlan(edit: dynamic, sourceSize: size)
            .viewports.viewport(at: 0.12).magnification
        #expect(earlyDynamic > earlySmooth)
        #expect(earlySmooth > 1)
    }

    @Test("An identity canvas still maps a point onto itself")
    func identityCardFillsTheFrame() {
        let plan = StudioRenderPlan(edit: edit(), sourceSize: size)
        #expect(plan.cardRect == CGRect(origin: .zero, size: size))
    }
}
