import AppKit
import AVFoundation
import Foundation

/// Cameras and microphones the recording picker can offer (docs/03 §1.8).
///
/// Names and ids only: `AVCaptureDevice` is not Sendable, and the picker lives in SwiftUI
/// on the main actor. The recorder looks a device back up from the stored id at the
/// moment it actually opens a capture session.
nonisolated enum RecordingDeviceCatalog {
    struct Device: Sendable, Identifiable, Hashable {
        var id: String {
            uniqueID
        }

        let uniqueID: String
        let localizedName: String
    }

    struct Display: Identifiable, Hashable {
        var id: CGDirectDisplayID {
            displayID
        }

        let displayID: CGDirectDisplayID
        let name: String
    }

    static func cameras() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.map { Device(uniqueID: $0.uniqueID, localizedName: $0.localizedName) }
    }

    static func microphones() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { Device(uniqueID: $0.uniqueID, localizedName: $0.localizedName) }
    }

    static func camera(withID uniqueID: String) -> AVCaptureDevice? {
        guard !uniqueID.isEmpty else { return nil }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first { $0.uniqueID == uniqueID }
    }

    @MainActor
    static func displays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return Display(
                displayID: CGDirectDisplayID(number.uint32Value),
                name: screen.localizedName
            )
        }
    }
}
