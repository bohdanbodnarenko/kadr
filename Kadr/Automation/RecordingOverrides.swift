import AutomationKit
import Foundation

/// Recording settings an automated recording overrides for one run (docs/03 §8.4).
///
/// Same rule as `CaptureOverrides`: `nil` means "use the setting", and the overrides die
/// with the recording rather than being written back to Settings.
struct RecordingOverrides: Sendable, Equatable {
    var frameRate: Int?
    var recordsMicrophone: Bool?
    var recordsSystemAudio: Bool?
    var exportAsGIF: Bool

    static let none = RecordingOverrides()

    init(
        frameRate: Int? = nil,
        recordsMicrophone: Bool? = nil,
        recordsSystemAudio: Bool? = nil,
        exportAsGIF: Bool = false
    ) {
        self.frameRate = frameRate
        self.recordsMicrophone = recordsMicrophone
        self.recordsSystemAudio = recordsSystemAudio
        self.exportAsGIF = exportAsGIF
    }

    init(_ options: RecordOptions) {
        self.init(
            frameRate: options.frameRate,
            recordsMicrophone: options.recordsMicrophone,
            recordsSystemAudio: options.recordsSystemAudio,
            exportAsGIF: options.exportAsGIF == true
        )
    }
}
