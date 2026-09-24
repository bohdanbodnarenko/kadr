import AppKit
import AVFoundation
import Foundation
import OverlayKit
import Shared

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

    static func microphone(withID uniqueID: String) -> AVCaptureDevice? {
        guard !uniqueID.isEmpty else { return nil }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.first { $0.uniqueID == uniqueID }
    }

    static func camera(withID uniqueID: String) -> AVCaptureDevice? {
        guard !uniqueID.isEmpty else { return nil }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first { $0.uniqueID == uniqueID }
    }

    /// The display under the pointer, which is where somebody is working — not the one
    /// with the menu bar (docs/17 T-REC-9).
    @MainActor
    static func pointerDisplayID() -> CGDirectDisplayID? {
        let pointer = ScreenPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        return SystemScreens().currentScreens().first { $0.frame.contains(pointer) }?.displayID
    }

    /// The pointer's screen, for panels that should appear where the user is looking.
    @MainActor
    static func pointerScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
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
