import AppKit
import SettingsKit
import Testing
@testable import Kadr

/// Record in the All-in-One island hands over to the recorder in place (docs/03 §1.4).
@MainActor
@Suite("Island hand-off")
struct IslandHandOffTests {
    @Test("The glass is the panel less its tooltip room and shadow slack")
    func barFrameInPanel() {
        let slack = RecordingBarMetrics.shadowSlack
        let panel = NSRect(x: 100, y: 20, width: 600, height: 52 + slack * 2 + RecordingBarMetrics.tooltipReserve)
        let bar = AllInOneHUD.barFrame(inPanel: panel)
        #expect(bar == NSRect(x: 100 + slack, y: 20 + slack, width: 600 - slack * 2, height: 52))
    }

    @Test("The recording bar opens with its glass on the island's glass", arguments: [
        NSRect(x: 300, y: 50, width: 480, height: 52),
        NSRect(x: 0, y: 700, width: 300, height: 96)
    ])
    func recordingBarLandsOnTheIsland(source: NSRect) {
        let origin = RecordingControlBar.panelOrigin(barBottomCentre: CGPoint(x: source.midX, y: source.minY))
        let panel = NSRect(origin: origin, size: RecordingControlBar.panelSize)
        // The floating bar is centred in its panel and sits `shadowSlack` above the bottom.
        #expect(panel.midX == source.midX)
        #expect(panel.minY + RecordingBarMetrics.shadowSlack == source.minY)
    }

    @Test("Record hands off; every other mode closes the island outright", arguments: AllInOneMode.allCases)
    func onlyRecordHandsOff(mode: AllInOneMode) {
        let model = AllInOneModel(settings: AppSettings(store: throwawayDefaults()), perform: { _ in })
        var picked = 0
        var handedOff = 0
        model.onPicked = { picked += 1 }
        model.onHandOff = { handedOff += 1 }
        model.pick(mode)
        #expect(handedOff == (mode == .record ? 1 : 0))
        #expect(picked == (mode == .record ? 0 : 1))
    }

    /// docs/18 CAP-4: a capture starts only after the target has had its activation back.
    @Test("A capture waits for the target before it runs")
    func captureWaitsForTarget() async {
        var performed: [AllInOneMode] = []
        let model = AllInOneModel(settings: AppSettings(store: throwawayDefaults())) { performed.append($0) }
        var waited = false
        model.waitForTarget = {
            #expect(performed.isEmpty, "the capture ran before the wait")
            waited = true
        }
        model.pick(.area)
        #expect(performed.isEmpty)
        while performed.isEmpty {
            await Task.yield()
        }
        #expect(waited)
        #expect(performed == [.area])
    }

    @Test("With no target there is nothing to wait for")
    func activationWaitWithoutTarget() async {
        let elapsed = await ContinuousClock().measure {
            await TargetActivation.wait(for: nil, ceiling: .seconds(60))
        }
        #expect(elapsed < .seconds(1))
    }

    /// A target that never activates must not hold the capture. The bound is loose because
    /// other suites share the main actor the deadline resumes on; the point is "returns".
    @Test("A target that never activates still lets the capture run")
    func activationWaitIsBounded() async {
        let elapsed = await ContinuousClock().measure {
            await TargetActivation.wait(for: pid_t(999_999), ceiling: .milliseconds(50))
        }
        #expect(elapsed < .seconds(15))
    }
}

@MainActor
@Suite("Recorder back to the island")
struct RecorderBackTests {
    @Test("Escape goes back when the recorder came from the island, and closes otherwise", arguments: [true, false])
    func escapeRouting(cameFromIsland: Bool) {
        let model = RecordSetupModel(settings: AppSettings(store: throwawayDefaults())) { _ in }
        var backs = 0
        var cancels = 0
        model.onBack = { backs += 1 }
        model.onCancel = { cancels += 1 }
        model.canGoBack = cameFromIsland
        model.escape()
        #expect(backs == (cameFromIsland ? 1 : 0))
        #expect(cancels == (cameFromIsland ? 0 : 1))
    }

    @Test("The island comes back with its glass on the recorder's")
    func islandLandsOnTheRecorder() {
        let bar = NSRect(x: 400, y: 60, width: 520, height: 52)
        let size = CGSize(width: 640, height: 160)
        let panel = AllInOneHUD.frame(for: size, onBar: bar)
        let glass = AllInOneHUD.barFrame(inPanel: panel)
        #expect(glass.midX == bar.midX)
        #expect(glass.minY == bar.minY)
    }
}
