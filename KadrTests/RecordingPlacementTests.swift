import CoreGraphics
import SettingsKit
import Testing
@testable import Kadr

/// docs/18 REC P3: the bar and the camera bubble come back where they were left.
@MainActor
@Suite("Recording placement", .serialized)
struct RecordingPlacementTests {
    @Test("Placement survives a new settings object over the same store")
    func survivesRelaunch() {
        let defaults = throwawayDefaults()
        RecordingPlacement.settings = AppSettings(store: defaults)
        defer { RecordingPlacement.settings = nil }
        RecordingPlacement.barOrigin = CGPoint(x: 120, y: 48)
        RecordingPlacement.cameraOrigin = CGPoint(x: 900, y: 30)
        RecordingPlacement.cameraDiameter = 220
        RecordingPlacement.cameraIsCircular = false

        // A relaunch: a fresh settings object reading what the last one wrote.
        RecordingPlacement.settings = AppSettings(store: defaults)
        #expect(RecordingPlacement.barOrigin == CGPoint(x: 120, y: 48))
        #expect(RecordingPlacement.cameraOrigin == CGPoint(x: 900, y: 30))
        #expect(RecordingPlacement.cameraDiameter == 220)
        #expect(!RecordingPlacement.cameraIsCircular)
    }

    @Test("Never placed reads as nil", arguments: [nil, "", "not a point"] as [String?])
    func neverPlaced(text: String?) {
        #expect(RecordingPlacement.point(text) == nil)
    }
}
