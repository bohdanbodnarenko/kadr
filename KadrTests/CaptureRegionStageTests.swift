import CoreGraphics
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// Where the Start button goes, and when the staged area goes away (docs/03 §1.6, §1.8).
@MainActor
@Suite("Capture region stage")
struct CaptureRegionStageTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 300, height: 110)

    @Test("The button sits where it should", arguments: [
        // A roomy area: centred inside it.
        (CGRect(x: 200, y: 200, width: 800, height: 500), CGPoint(x: 450, y: 395)),
        // Too short: just below it.
        (CGRect(x: 200, y: 400, width: 800, height: 60), CGPoint(x: 450, y: 274)),
        // Too short and on the bottom edge: just above it.
        (CGRect(x: 200, y: 0, width: 800, height: 60), CGPoint(x: 450, y: 76)),
        // Hard against the left: pulled back on screen.
        (CGRect(x: 0, y: 400, width: 100, height: 60), CGPoint(x: 16, y: 274))
    ])
    func placement(hole: CGRect, expected: CGPoint) {
        let frame = CaptureRegionStage.controlFrame(size: size, hole: hole, visible: visible)
        #expect(frame.origin == expected)
        #expect(frame.size == size)
        #expect(visible.contains(frame))
    }

    @Test("Arming anything reports it, so the staged area can go")
    func armedTargetChangesAreReported() {
        let model = RecordSetupModel(settings: AppSettings(store: throwawayDefaults()), record: { _ in })
        var seen: [RecordArmedTarget?] = []
        model.onArmedTargetChanged = { seen.append($0) }
        let area = RecordArmedTarget.area(DisplayRect(cgRect: CGRect(x: 0, y: 0, width: 10, height: 10)), display: 1)
        model.armedTarget = area
        model.armScreen(1)
        #expect(seen == [area, .screen(1)])
    }
}
