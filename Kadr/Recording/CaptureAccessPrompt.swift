import AppKit
import AVFoundation
import SwiftUI

/// Camera or microphone access needed before a recording option is used (docs/14 UX-17).
enum CaptureAccessKind: String, Identifiable, Equatable, Sendable {
    case camera
    case microphone

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        }
    }

    var prompt: String {
        switch self {
        case .camera:
            String(localized: "Recording your camera needs permission. You can start without it.")
        case .microphone:
            String(localized: "Recording your microphone needs permission. You can start without it.")
        }
    }

    var permission: AppPermission {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        }
    }
}

enum CaptureAccessResume: Equatable {
    case toggle
    case begin(RecordTargetKind)
    case beginDisplay(CGDirectDisplayID)
}

enum CaptureAccessGate {
    static func needsPrompt(status: AppPermissionStatus) -> Bool {
        status != .allowed
    }
}

enum CaptureMediaAccess {
    static func status(for kind: CaptureAccessKind) -> AppPermissionStatus {
        switch kind {
        case .camera:
            AppPermissionStatus.media(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            AppPermissionStatus.media(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    static func request(_ kind: CaptureAccessKind) async -> Bool {
        switch kind {
        case .camera:
            await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    static func openSystemSettings(_ kind: CaptureAccessKind) {
        NSWorkspace.shared.open(kind.permission.settingsURL)
    }
}

struct CaptureAccessPromptView: View {
    let kind: CaptureAccessKind
    var onAllow: () -> Void
    var onOpenSettings: () -> Void
    var onUseWithout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title)
                .font(.headline)
            Text(kind.prompt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use Without", action: onUseWithout)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button("Open Settings", action: onOpenSettings)
                Button("Allow", action: onAllow)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }
}
