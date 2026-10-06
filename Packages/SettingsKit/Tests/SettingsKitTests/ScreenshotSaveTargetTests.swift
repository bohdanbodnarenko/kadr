import Testing
@testable import SettingsKit

/// The island's Save menu writes the after-capture matrix (docs/17 T-CAP-12).
@Suite("Screenshot save target")
struct ScreenshotSaveTargetTests {
    private static let rows: [(AfterCaptureActions, ScreenshotSaveTarget)] = [
        ([.overlay, .copy], .none),
        ([.overlay, .save], .folder),
        ([.copy, .promptSave], .ask),
        ([.save, .promptSave], .ask)
    ]

    @Test("Reading the target from a row", arguments: 0 ..< rows.count)
    func reads(index: Int) {
        let (row, expected) = Self.rows[index]
        var matrix = AfterCaptureMatrix.standard
        matrix[.screenshot] = row
        #expect(matrix.screenshotSaveTarget == expected)
    }

    @Test("Writing a target touches only the save actions", arguments: ScreenshotSaveTarget.allCases)
    func writes(target: ScreenshotSaveTarget) {
        var matrix = AfterCaptureMatrix.standard
        matrix[.screenshot] = [.overlay, .copy, .pin, .save]
        let recording = matrix[.recording]
        matrix.screenshotSaveTarget = target

        #expect(matrix.screenshotSaveTarget == target)
        #expect(matrix[.screenshot].isSuperset(of: [.overlay, .copy, .pin]))
        #expect(matrix[.recording] == recording)
    }

    @Test("Choosing not to save never leaves a capture with nowhere to go")
    func noneKeepsCard() {
        var matrix = AfterCaptureMatrix.standard
        matrix[.screenshot] = [.save]
        matrix.screenshotSaveTarget = .none
        #expect(matrix[.screenshot] == [.overlay])
    }
}
