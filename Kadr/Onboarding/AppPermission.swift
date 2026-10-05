import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import SwiftUI

/// Every TCC grant Kadr actually uses (docs/03 §8.2).
///
/// Screen Recording is required for capture. The rest are optional features that stay
/// off until the user turns them on — onboarding lists them so a denied ask later is
/// never a surprise, and Settings recovers the same rows for people who skipped.
enum AppPermission: String, CaseIterable, Identifiable, Sendable {
    case screen
    case accessibility
    case inputMonitoring
    case microphone
    case camera

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .screen: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
    }

    var displayTitle: String {
        self == .screen ? "Screen capture" : title
    }

    var symbol: String {
        switch self {
        case .screen: "desktopcomputer"
        case .accessibility: "hand.point.up.left"
        case .inputMonitoring: "keyboard"
        case .microphone: "mic"
        case .camera: "video"
        }
    }

    var explanation: String {
        switch self {
        case .screen: "Screenshots, recordings and system audio. Nothing leaves this Mac."
        case .accessibility: "Auto-scroll a long page, and show keys while recording (with Input Monitoring)."
        case .inputMonitoring: "Read clicks and shortcuts for the studio and key overlays. Never plain typing."
        case .microphone: "Add your voice to a recording, as its own track."
        case .camera: "Show a webcam beside the screen, only while that recording runs."
        }
    }

    var isRequired: Bool {
        self == .screen
    }

    /// These grants attach to a newly launched process, not the one that asked.
    var mayNeedRelaunch: Bool {
        switch self {
        case .screen, .accessibility, .inputMonitoring: true
        case .microphone, .camera: false
        }
    }

    var settingsURL: URL {
        let pane = switch self {
        case .screen: "ScreenCapture"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "ListenEvent"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")
            ?? URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane")
    }

    func needsSettings(status: AppPermissionStatus, attempted: Bool) -> Bool {
        status == .denied || (mayNeedRelaunch && attempted && status == .notEnabled)
    }

    /// Required or Optional, as a word rather than a colour (docs/14 UX-06).
    var requirementLabel: String {
        isRequired ? "Required" : "Optional"
    }

    /// The one recovery instruction for the current state (docs/14 UX-06).
    ///
    /// One sentence, never a stack of them. The relaunch caveat belongs to a single row
    /// per screen — `includesRelaunchGuidance` — because repeating “reopen Kadr” under
    /// three rows reads as three separate problems instead of one fact about macOS.
    func recovery(
        status: AppPermissionStatus,
        attempted: Bool,
        includesRelaunchGuidance: Bool
    ) -> String? {
        switch status {
        case .allowed:
            return nil
        case .restricted:
            return "Restricted by this Mac’s administrator. Kadr works without it."
        case .notEnabled, .denied:
            guard needsSettings(status: status, attempted: attempted) else { return nil }
            let route = "In Privacy & Security → \(title), turn on Kadr."
            guard includesRelaunchGuidance, mayNeedRelaunch else { return route }
            return route + " macOS applies it the next time Kadr opens."
        }
    }
}

/// What macOS currently says about one grant.
enum AppPermissionStatus: Equatable, Sendable {
    case notEnabled
    case allowed
    case denied
    case restricted

    var label: String {
        switch self {
        case .notEnabled: "Not enabled"
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted on this Mac"
        }
    }

    static func media(_ status: AVAuthorizationStatus) -> Self {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notEnabled
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

/// Reads and requests TCC grants without prompting except when asked to.
///
/// Injected so onboarding tests never touch the real TCC database.
protocol AppPermissionSampling: Sendable {
    func status(of permission: AppPermission) -> AppPermissionStatus
    func request(_ permission: AppPermission) async
}

struct SystemAppPermissionSampling: AppPermissionSampling {
    func status(of permission: AppPermission) -> AppPermissionStatus {
        switch permission {
        case .screen:
            CGPreflightScreenCaptureAccess() ? .allowed : .notEnabled
        case .accessibility:
            AXIsProcessTrusted() ? .allowed : .notEnabled
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .allowed : .notEnabled
        case .microphone:
            .media(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            .media(AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    func request(_ permission: AppPermission) async {
        switch permission {
        case .screen:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let prompt = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
    }
}

/// Required or Optional as a semantic badge (docs/14 UX-06).
///
/// Hidden from VoiceOver on purpose: the same word is folded into the row title's label,
/// so a reader hears “Screen capture, required” once instead of twice.
struct AppPermissionBadge: View {
    let permission: AppPermission

    var body: some View {
        Text(permission.requirementLabel)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(permission.isRequired ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    (permission.isRequired ? Color.accentColor : Color.secondary).opacity(0.14)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    (permission.isRequired ? Color.accentColor : Color.secondary).opacity(0.35)
                )
            )
            .accessibilityHidden(true)
    }
}

/// One compact permission row, shared by onboarding and Settings (docs/14 UX-06).
struct AppPermissionRow: View {
    let permission: AppPermission
    let status: AppPermissionStatus
    var attempted = false
    var isRequesting = false
    var requestsDisabled = false
    /// True for the one row per screen that carries the “reopen Kadr” caveat.
    var showsRelaunchGuidance = false
    var errorMessage: String?
    var request: () -> Void
    var openSettings: () -> Void

    /// Narrowest copy column that still reads as a paragraph rather than a column of
    /// single words. Below that the action moves under the copy instead of compressing
    /// the title, which is the whole point of the `ViewThatFits` below.
    private static let copyIdealWidth: CGFloat = 260
    private static let actionWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                actionBesideCopy
                actionBelowCopy
            }
            if let recovery = permission.recovery(
                status: status,
                attempted: attempted,
                includesRelaunchGuidance: showsRelaunchGuidance
            ) {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Layouts

    private var actionBesideCopy: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            copy
                .frame(idealWidth: Self.copyIdealWidth, alignment: .leading)
            Spacer(minLength: 12)
            action
                .frame(minWidth: Self.actionWidth, alignment: .trailing)
        }
    }

    private var actionBelowCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                icon
                copy
                Spacer(minLength: 0)
            }
            action
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var icon: some View {
        Image(systemName: permission.symbol)
            .font(.system(size: 18))
            .foregroundStyle(permission.isRequired ? Color.accentColor : .secondary)
            .frame(width: 28)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(permission.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                AppPermissionBadge(permission: permission)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(permission.displayTitle), \(permission.requirementLabel)")
            Text(permission.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var action: some View {
        if isRequesting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Waiting for \(permission.displayTitle) permission")
        } else if status == .allowed {
            Label {
                Text("Allowed")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption.weight(.medium))
            .accessibilityLabel("\(permission.displayTitle) access allowed")
        } else if status == .restricted {
            Label("Restricted", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let settings = permission.needsSettings(status: status, attempted: attempted)
            Button(settings ? "Open Settings" : "Allow", action: settings ? openSettings : request)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(requestsDisabled)
                .tint(permission.isRequired && !settings ? .accentColor : nil)
                .accessibilityLabel(
                    settings
                        ? "Open \(permission.title) settings"
                        : "Allow \(permission.displayTitle) access"
                )
        }
    }
}
