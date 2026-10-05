import Foundation
import Testing
@testable import EditorUI

/// The export sheet's one size control and its time-left estimate (docs/18 STU-13).
@Suite("Export sheet")
struct StudioExportSheetTests {
    @Test("Each size step maps to one compression and quality, and back", arguments: StudioExportSettings.SizePreset.allCases)
    func sizePresetRoundTrips(preset: StudioExportSettings.SizePreset) {
        var settings = StudioExportSettings()
        settings.sizePreset = preset
        #expect(settings.sizePreset == preset)
        #expect(settings.compresses == (preset != .best))
    }

    @Test("A remembered uncompressed choice keeps its intent", arguments: [
        (StudioExportSettings.Quality.high, StudioExportSettings.SizePreset.best),
        (.medium, .smaller),
        (.low, .smallest)
    ])
    func legacyUncompressed(quality: StudioExportSettings.Quality, expected: StudioExportSettings.SizePreset) throws {
        let legacy = StudioExportSettings(quality: quality, compresses: false)
        let decoded = try JSONDecoder().decode(StudioExportSettings.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.sizePreset == expected)
    }

    @Test("Time left is linear in progress, and silent at the start", arguments: [
        (0.01, 10.0, nil as TimeInterval?),
        (0.25, 30.0, 90.0),
        (0.5, 60.0, 60.0),
        (1.0, 120.0, nil)
    ])
    func timeLeft(progress: Double, elapsed: TimeInterval, expected: TimeInterval?) {
        #expect(StudioDocumentModel.exportTimeLeft(progress: progress, elapsed: elapsed) == expected)
    }
}
