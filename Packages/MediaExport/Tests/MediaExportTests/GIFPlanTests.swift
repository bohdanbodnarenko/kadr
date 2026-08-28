import CoreGraphics
import Foundation
import Testing
@testable import MediaExport

/// Planning a GIF encode to fit memory (docs/03 §1.8, docs/07 M10, docs/09 U0.5).
///
/// The review's finding: `CGImageDestination` holds every frame added to a GIF until
/// `finalize`, so peak RAM is the whole GIF's worth of decoded frames. The code's comment
/// claimed one frame at a time. A five-minute recording is enough to have the encoder
/// killed. These tests pin the arithmetic that decides what to give up instead.
@Suite("GIF plan")
struct GIFPlanTests {
    private let hd = CGSize(width: 1920, height: 1080)

    private func plan(
        seconds: Double,
        frameSize: CGSize? = nil,
        options: GIFOptions = GIFOptions()
    ) -> GIFPlan {
        GIFPlan.fitting(sourceSeconds: seconds, frameSize: frameSize ?? hd, options: options)
    }

    @Test("A short clip is encoded exactly as asked")
    func shortClipIsUntouched() {
        let plan = plan(seconds: 5)
        #expect(plan.frameRate == 15)
        #expect(plan.maximumWidth == 800)
        #expect(!plan.isClipped)
        #expect(!plan.isReduced)
        #expect(plan.encodedSeconds == 5)
    }

    /// The failure scenario from the review, as a budget assertion.
    @Test(
        "However long the recording, the encode stays inside its memory budget",
        arguments: [10.0, 60, 300, 3600]
    )
    func peakStaysInBudget(seconds: Double) {
        let options = GIFOptions()
        let plan = plan(seconds: seconds, options: options)
        #expect(
            plan.estimatedPeakBytes <= options.peakMemoryBudget,
            "\(seconds)s planned to \(plan.estimatedPeakBytes) bytes"
        )
    }

    /// The order of the concessions is the design: a slower, smaller GIF is still the
    /// whole recording; a clipped one is not.
    @Test("Frame rate goes first, then size, and length last")
    func concessionOrder() {
        // Long enough to need the frame rate lowered, not so long that it must be cut.
        let modest = plan(seconds: 120)
        #expect(modest.frameRate < 15, "the rate should come down before anything else")
        #expect(!modest.isClipped, "two minutes should still fit whole")

        // Long enough that even the floors cannot hold it.
        let enormous = plan(seconds: 3600)
        #expect(enormous.frameRate == GIFPlan.minimumFrameRate)
        #expect(enormous.maximumWidth == GIFPlan.minimumWidth)
        #expect(enormous.isClipped)
    }

    @Test("Neither floor is crossed, however long the clip")
    func floorsHold() {
        let plan = plan(seconds: 86400)
        #expect(plan.frameRate >= GIFPlan.minimumFrameRate)
        #expect(plan.maximumWidth >= GIFPlan.minimumWidth)
        #expect(plan.encodedSeconds > 0, "there is always some GIF to make")
    }

    @Test("A clipped plan says so, and says how much it covers")
    func clippingIsReported() {
        let plan = plan(seconds: 3600)
        #expect(plan.isClipped)
        #expect(plan.isReduced)
        #expect(plan.encodedSeconds < plan.sourceSeconds)
        #expect(plan.sourceSeconds == 3600)
    }

    /// A small source is never scaled *up* to the limit — the GIF should not be bigger
    /// than the recording.
    @Test("A recording narrower than the limit keeps its own width")
    func smallSourceKeepsItsWidth() {
        let plan = plan(seconds: 5, frameSize: CGSize(width: 320, height: 240))
        #expect(plan.maximumWidth == 320)
    }

    @Test("A bigger budget buys back quality")
    func budgetChangesThePlan() {
        let tight = plan(seconds: 120, options: GIFOptions(peakMemoryBudget: 32 * 1024 * 1024))
        let roomy = plan(seconds: 120, options: GIFOptions(peakMemoryBudget: 4 * 1024 * 1024 * 1024))
        #expect(roomy.frameRate >= tight.frameRate)
        #expect(roomy.maximumWidth >= tight.maximumWidth)
        #expect(roomy.encodedSeconds >= tight.encodedSeconds)
    }

    @Test("An empty recording plans nothing rather than dividing by zero")
    func zeroDuration() {
        let plan = plan(seconds: 0)
        #expect(plan.frameCount == 0)
        #expect(plan.estimatedPeakBytes == 0)
        #expect(!plan.isClipped)
    }

    @Test("A degenerate frame size does not crash the planner")
    func zeroFrameSize() {
        let plan = plan(seconds: 10, frameSize: .zero)
        #expect(plan.encodedSeconds == 10)
        #expect(plan.frameCount > 0)
    }

    @Test("The requested settings are kept, so a reduction is visible")
    func requestedSettingsAreRemembered() {
        let plan = plan(seconds: 600, options: GIFOptions(frameRate: 30, maximumWidth: 1200))
        #expect(plan.requestedFrameRate == 30)
        #expect(plan.requestedWidth == 1200)
        #expect(plan.isReduced)
    }
}
