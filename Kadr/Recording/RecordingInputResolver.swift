import AVFoundation
import RecordingCore

/// Validates recording devices and permissions before start (docs/16 REC-14).
///
/// Never prompts. A missing or unauthorised device is dropped and reported, rather than
/// silently falling back to a Continuity camera.
struct RecordingInputResolution: Sendable {
    var options: RecordingOptions
    var cameraDeviceID: String
    var notice: String?
}

enum RecordingInputResolver {
    static func resolve(
        options: RecordingOptions,
        cameraDeviceID: String
    ) -> RecordingInputResolution {
        var options = options
        var camera = cameraDeviceID
        var notices: [String] = []

        if options.capturesMicrophone {
            if let id = options.microphoneDeviceID, RecordingDeviceCatalog.microphone(withID: id) == nil {
                options.microphoneDeviceID = nil
                options.capturesMicrophone = false
                notices.append("Microphone unavailable — recording without it.")
            } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                options.capturesMicrophone = false
                notices.append("Microphone permission is off — recording without it.")
            }
        }

        if !camera.isEmpty {
            if RecordingDeviceCatalog.camera(withID: camera) == nil {
                camera = ""
                notices.append("Camera unavailable — recording without it.")
            } else if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                camera = ""
                notices.append("Camera permission is off — recording without it.")
            }
        }

        return RecordingInputResolution(
            options: options,
            cameraDeviceID: camera,
            notice: notices.first
        )
    }
}
