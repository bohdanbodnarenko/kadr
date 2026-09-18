import Testing
@testable import CaptureCore

/// How far auto-scroll moves per step, and how it delivers it (docs/03 §1.6).
@Suite("Auto-scroll steps")
struct AutoScrollPlanTests {
    struct StepCase {
        let name: String
        let requested: Int
        let region: Int
        let expected: Int
    }

    @Test("A step always leaves the stitcher something to match on", arguments: [
        StepCase(name: "a tall window takes the requested step", requested: 120, region: 900, expected: 120),
        StepCase(name: "a short one is capped to 60% of itself", requested: 120, region: 150, expected: 90),
        StepCase(name: "the cap wins over the floor", requested: 400, region: 50, expected: 30),
        StepCase(name: "a small request is raised to the floor", requested: 5, region: 900, expected: 40),
        StepCase(name: "a tiny region still advances", requested: 120, region: 10, expected: 6),
        StepCase(name: "a degenerate region never returns zero", requested: 120, region: 0, expected: 1)
    ])
    func stepPoints(_ testCase: StepCase) {
        let step = AutoScrollPlan.stepPoints(requested: testCase.requested, regionPoints: testCase.region)
        #expect(step == testCase.expected, "\(testCase.name)")
    }

    @Test("Never more than 60% of the frame, whatever is asked for", arguments: [40, 120, 400, 4000])
    func stepAlwaysLeavesOverlap(requested: Int) {
        for region in stride(from: 80, through: 2000, by: 120) {
            let step = AutoScrollPlan.stepPoints(requested: requested, regionPoints: region)
            #expect(Double(step) <= Double(region) * AutoScrollPlan.maximumStepFraction + 1)
            #expect(step >= 1)
        }
    }

    @Test("A step is delivered as pulses that add up to it", arguments: [1, 39, 40, 41, 90, 120, 480])
    func pulsesSumToTheStep(step: Int) {
        let pulses = AutoScrollPlan.pulses(forStep: step)

        #expect(pulses.reduce(0, +) == step)
        #expect(pulses.allSatisfy { $0 >= 1 })
        // Nothing big enough for an app to read as a flick.
        #expect(pulses.allSatisfy { $0 <= AutoScrollPlan.maximumPulsePoints })
        // Even-paced: the page should not lurch and then crawl inside one step.
        #expect((pulses.max() ?? 0) - (pulses.min() ?? 0) <= 1)
    }

    @Test("No step, no pulses")
    func emptyStep() {
        #expect(AutoScrollPlan.pulses(forStep: 0).isEmpty)
        #expect(AutoScrollPlan.pulses(forStep: -10).isEmpty)
    }
}
