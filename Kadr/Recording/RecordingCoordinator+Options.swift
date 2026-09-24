import Foundation
import RecordingCore
import SettingsKit

/// What the next take records with, from the settings and any one-run overrides.
@MainActor
extension RecordingCoordinator {
    var currentOptions: RecordingOptions {
        let requestedRate = overrides.frameRate ?? settings.recordingFrameRate.rawValue
        return RecordingOptions(
            // An automation may ask for a frame rate the encoder presets do not have; the
            // nearest preset is a better answer than refusing the recording.
            frameRate: RecordingFrameRate.nearest(to: requestedRate),
            codec: settings.recordingCodec == .hevc ? .hevc : .h264,
            capturesSystemAudio: overrides.recordsSystemAudio ?? settings.recordsSystemAudio,
            capturesMicrophone: overrides.recordsMicrophone ?? settings.recordsMicrophone,
            microphoneDeviceID: settings.recordingMicrophoneDeviceID.isEmpty
                ? nil
                : settings.recordingMicrophoneDeviceID,
            showsCursor: showsCursor,
            dynamicRange: settings.recordingDynamicRange,
            recordsMono: settings.recordsMono
        )
    }

    /// Whether the system cursor is baked into the recording.
    ///
    /// Left out only when the user has asked the studio to draw it back, and only when
    /// there is a session to draw it back from. A cursor cannot be added to footage that
    /// never had one and has no sidecar either, so recording without one in that case would
    /// simply lose the pointer (docs/09 U3.1).
    var showsCursor: Bool {
        guard settings.recordingReconstructsCursor, capturesStudioSession else {
            return settings.recordingShowsCursor
        }
        return false
    }
}

/// What VoiceOver is told when a take changes state, if anything.
nonisolated enum RecordingAnnouncement {
    static func message(from old: RecordingState, to new: RecordingState) -> String? {
        switch (old, new) {
        case (.starting, .recording): String(localized: "Recording started")
        case (.recording, .paused): String(localized: "Recording paused")
        case (.paused, .recording): String(localized: "Recording resumed")
        case (_, .finishing): String(localized: "Saving recording")
        case (.finishing, .idle): String(localized: "Recording saved")
        case (.recording, .idle), (.paused, .idle): String(localized: "Recording discarded")
        default: nil
        }
    }
}
