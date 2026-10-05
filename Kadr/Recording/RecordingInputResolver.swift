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
    /// The take asked for a microphone and will record without one (docs/18 REC-1).
    var droppedMicrophone = false
}

enum RecordingInputResolver {
    static func resolve(
        options: RecordingOptions,
        cameraDeviceID: String,
        wantsCamera: Bool = false,
        defaultCamera: () -> String? = RecordingInputResolver.defaultCameraID
    ) -> RecordingInputResolution {
        var options = options
        var camera = cameraDeviceID
        var notices: [String] = []
        var droppedMicrophone = false

        // The camera switched on from Settings or the pre-roll never chose a device, so the
        // take recorded no camera at all (docs/17 T-REC-9). Take the system's default.
        if wantsCamera, camera.isEmpty {
            camera = defaultCamera() ?? ""
            if camera.isEmpty {
                notices.append("No camera found — recording without it.")
            }
        }

        if options.capturesMicrophone {
            if let id = options.microphoneDeviceID, RecordingDeviceCatalog.microphone(withID: id) == nil {
                options.microphoneDeviceID = nil
                options.capturesMicrophone = false
                notices.append("Microphone unavailable — recording without it.")
                droppedMicrophone = true
            } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                options.capturesMicrophone = false
                notices.append("Microphone permission is off — recording without it.")
                droppedMicrophone = true
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
            // The microphone first: a silent narration is the costliest loss.
            notice: droppedMicrophone ? notices.first { $0.hasPrefix("Microphone") } : notices.first,
            droppedMicrophone: droppedMicrophone
        )
    }

    /// The system's default camera, or the first one attached.
    nonisolated static func defaultCameraID() -> String? {
        AVCaptureDevice.default(for: .video)?.uniqueID
            ?? RecordingDeviceCatalog.cameras().first?.uniqueID
    }
}
