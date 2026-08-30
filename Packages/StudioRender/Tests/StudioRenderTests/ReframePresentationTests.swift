import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Where the picture goes inside the output frame (docs/11 S0.5).
///
/// "Show everything" was the control that did neither thing it offered. `Reframe.fit` hands
/// back the whole recording and comments that "the bars are the renderer's business"; the
/// renderer had no bar logic at all — it scaled by width and never centred. A landscape
/// recording ended up flush against the bottom of a 9:16 frame under a 739-pixel black bar,
/// and a portrait one exported 16:9 was *cropped*, which is the one thing the control
/// promises not to do.
@Suite("Reframe presentation")
struct ReframePresentationTests {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let portrait = CGSize(width: 1080, height: 1920)

    private func plan(_ source: CGSize, _ reframe: Reframe) -> StudioRenderPlan {
        var edit = StudioEdit.untouched(duration: 10)
        edit.reframe = reframe
        return StudioRenderPlan(edit: edit, sourceSize: source)
    }

    private func fit(_ aspect: ReframeAspect) -> Reframe {
        Reframe(aspect: aspect, fill: .fit)
    }

    // MARK: - Nothing is cropped

    /// The headline: everything the recording contains has to survive.
    @Test(
        "Show everything keeps the whole recording inside the frame",
        arguments: [
            (CGSize(width: 1920, height: 1080), ReframeAspect.nineSixteen),
            (CGSize(width: 1080, height: 1920), ReframeAspect.sixteenNine),
            (CGSize(width: 1920, height: 1080), ReframeAspect.square),
            (CGSize(width: 1080, height: 1920), ReframeAspect.square)
        ]
    )
    func showEverythingCropsNothing(source: CGSize, aspect: ReframeAspect) {
        let plan = plan(source, fit(aspect))
        let rect = plan.sourceRect(at: 0)
        let presentation = plan.presentation(for: rect)

        let drawn = CGSize(
            width: rect.width * presentation.scale,
            height: rect.height * presentation.scale
        )
        // A tenth of a pixel of slack for the plan's rounding to even dimensions.
        #expect(drawn.width <= plan.outputSize.width + 0.1, "the picture is wider than the frame")
        #expect(drawn.height <= plan.outputSize.height + 0.1, "the picture is taller than the frame")
    }

    /// And it has to be as large as it can be — a fit that shrank everything to a dot would
    /// also crop nothing.
    @Test("Show everything fills one axis exactly")
    func showEverythingTouchesAnEdge() {
        let plan = plan(landscape, fit(.nineSixteen))
        let rect = plan.sourceRect(at: 0)
        let presentation = plan.presentation(for: rect)

        let drawn = CGSize(
            width: rect.width * presentation.scale,
            height: rect.height * presentation.scale
        )
        let touchesWidth = abs(drawn.width - plan.outputSize.width) < 0.1
        let touchesHeight = abs(drawn.height - plan.outputSize.height) < 0.1
        #expect(touchesWidth || touchesHeight, "the picture is smaller than it needs to be")
    }

    /// The letterbox is split between the two bars rather than all being on one side.
    @Test("The bars are equal, not all at one end")
    func barsAreCentred() {
        let plan = plan(landscape, fit(.nineSixteen))
        let rect = plan.sourceRect(at: 0)
        let presentation = plan.presentation(for: rect)

        let leftover = plan.outputSize.height - rect.height * presentation.scale
        #expect(leftover > 1, "this fixture is supposed to letterbox")
        #expect(
            abs(presentation.origin.y - leftover / 2) < 0.1,
            "the content sat at \(presentation.origin.y) with \(leftover) of bar to share"
        )
    }

    // MARK: - The overlays go through the same mapping

    /// A cursor has to land on the picture, not on a bar. Mapping each axis onto the full
    /// output independently — which is what `outputPoint` used to do — stretches the
    /// pointer path across the letterbox while the picture underneath stays put.
    @Test("A recorded point lands on the picture it was recorded over")
    func pointsFollowThePicture() {
        let plan = plan(landscape, fit(.nineSixteen))
        let rect = plan.sourceRect(at: 0)
        let presentation = plan.presentation(for: rect)
        let top = presentation.origin.y
        let bottom = top + rect.height * presentation.scale

        // The centre of the recording is the centre of the frame.
        let centre = plan.outputPoint(CGPoint(x: 960, y: 540), in: rect)
        #expect(abs(centre.x - plan.outputSize.width / 2) < 0.5)
        #expect(abs(centre.y - plan.outputSize.height / 2) < 0.5)

        // And the corners are on the picture's own edges, inside the bars.
        let topLeft = plan.outputPoint(.zero, in: rect)
        #expect(abs(topLeft.y - top) < 0.5, "the top of the recording is not the top of the picture")
        let bottomRight = plan.outputPoint(CGPoint(x: 1920, y: 1080), in: rect)
        #expect(abs(bottomRight.y - bottom) < 0.5)
    }

    /// Aspect ratio is preserved, which is the same statement as "the scale is one number".
    @Test("Nothing is stretched")
    func aspectIsPreserved() {
        for aspect in [ReframeAspect.nineSixteen, .square, .sixteenNine, .fourFive] {
            for source in [landscape, portrait] {
                let plan = plan(source, fit(aspect))
                let rect = plan.sourceRect(at: 0)
                let presentation = plan.presentation(for: rect)
                let drawnAspect = (rect.width * presentation.scale) / (rect.height * presentation.scale)
                #expect(abs(drawnAspect - rect.width / rect.height) < 0.0001)
            }
        }
    }

    // MARK: - The cases that must not have moved

    /// Original and `.fill` hand back a rect that already matches the output's shape, so
    /// both axes give the same scale and there is nothing to centre. If this changed, the
    /// fix broke the common path to repair the rare one.
    @Test(
        "An unreframed recording is untouched",
        arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)]
    )
    func originalIsUnchanged(source: CGSize) {
        let plan = plan(source, Reframe())
        let rect = plan.sourceRect(at: 0)
        let presentation = plan.presentation(for: rect)

        #expect(abs(presentation.scale - 1) < 0.0001)
        #expect(abs(presentation.origin.x) < 0.0001)
        #expect(abs(presentation.origin.y) < 0.0001)
    }

    /// "Fill the frame" covers it and lets the surplus be cropped, which is not the same as
    /// fitting inside it. The output is rounded to even pixels, so even a crop whose shape
    /// already matches has a pixel or so of slack — fitting that slack put a thin black line
    /// along the top and bottom of an export that had asked for no bars at all.
    @Test(
        "Filling the frame covers it rather than leaving a sliver of bar",
        arguments: [
            (CGSize(width: 1920, height: 1080), ReframeAspect.nineSixteen),
            (CGSize(width: 1080, height: 1920), ReframeAspect.sixteenNine),
            (CGSize(width: 1920, height: 1080), ReframeAspect.square)
        ]
    )
    func fillCoversTheFrame(source: CGSize, aspect: ReframeAspect) {
        let plan = plan(source, Reframe(aspect: aspect, fill: .fill))
        let rect = plan.sourceRect(at: 0)
        let presentation = plan.presentation(for: rect)

        #expect(rect.width * presentation.scale >= plan.outputSize.width - 0.001)
        #expect(rect.height * presentation.scale >= plan.outputSize.height - 0.001)
        // Any surplus is split between the two edges rather than all taken off one.
        #expect(presentation.origin.x <= 0.001)
        #expect(presentation.origin.y <= 0.001)
        // And the surplus is a rounding artefact, not a crop somebody would notice.
        #expect(abs(presentation.origin.x) < 2)
        #expect(abs(presentation.origin.y) < 2)
    }

    /// A zoom still magnifies, because `scale(at:)` now goes through the presentation and a
    /// mistake there would silently stop every cue from doing anything.
    @Test("A zoom still magnifies")
    func zoomStillMagnifies() {
        var edit = StudioEdit.untouched(duration: 10)
        edit.zooms = [ZoomCue(
            start: 2,
            duration: 4,
            magnification: 2,
            anchor: .fixed(CGPoint(x: 960, y: 540)),
            transitionDuration: 0.5
        )]
        let plan = StudioRenderPlan(edit: edit, sourceSize: landscape)

        #expect(abs(plan.scale(at: 0) - 1) < 0.01, "the recording is magnified before the cue starts")
        #expect(plan.scale(at: 4) > 1.8, "a 2× cue magnified by \(plan.scale(at: 4))×")
    }
}
