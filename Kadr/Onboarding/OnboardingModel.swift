import AppKit
import CaptureCore
import Foundation
import os
import SettingsKit
import Shared

/// The three onboarding screens (docs/03 §8.2).
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case screenRecording
    case defaults

    var title: String {
        switch self {
        case .welcome: "Welcome to Kadr"
        case .screenRecording: "Let Kadr see your screen"
        case .defaults: "How should captures behave?"
        }
    }
}

/// Drives onboarding and the permission recovery it shares with the rest of the app
/// (docs/03 §8.2, docs/04 §4.1).
@MainActor
@Observable
final class OnboardingModel {
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let loginItem: LoginItemController
    @ObservationIgnored private let relauncher: RelaunchHelper
    @ObservationIgnored private let logger = KadrLog.logger(.app)

    var step: OnboardingStep = .welcome
    /// Set when the grant arrived mid-session and the app has to restart to use it.
    private(set) var needsRelaunch = false

    /// Called when the user finishes or skips.
    var onFinish: (() -> Void)?

    init(
        permissions: PermissionCoordinator,
        settings: AppSettings,
        loginItem: LoginItemController,
        relauncher: RelaunchHelper = RelaunchHelper()
    ) {
        self.permissions = permissions
        self.settings = settings
        self.loginItem = loginItem
        self.relauncher = relauncher
    }

    var permissionState: ScreenRecordingPermission {
        permissions.state
    }

    var loginItemState: LoginItemState {
        loginItem.state
    }

    var appSettings: AppSettings {
        settings
    }

    var isLastStep: Bool {
        step == OnboardingStep.allCases.last
    }

    func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = next
        // Polling happens only while this screen is on show — the app's one poll
        // (docs/04 §4.1).
        if next == .screenRecording {
            startWatchingForGrant()
        } else {
            permissions.endProbing()
        }
    }

    func skip() {
        finish()
    }

    private func finish() {
        permissions.endProbing()
        settings.hasCompletedOnboarding = true
        onFinish?()
    }

    // MARK: - Screen Recording

    /// Asks macOS for the grant, which shows the system prompt exactly once per app.
    func requestScreenRecording() {
        permissions.requestAccess()
        startWatchingForGrant()
    }

    /// Deep-links to the exact System Settings pane, because "open System Settings and
    /// find it" is where most people give up.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        guard let url else { return }
        NSWorkspace.shared.open(url)
        startWatchingForGrant()
    }

    /// Watches for the grant appearing while the user is in System Settings.
    ///
    /// macOS sends no notification when the switch is flipped, so this is the one place
    /// in the app that polls — and it stops the moment the answer arrives or the screen
    /// goes away (PRD §8: zero timers at idle).
    func startWatchingForGrant() {
        // Read the current answer before polling for a change in it: without this, a
        // grant arriving during onboarding looks like the state it launched in, and the
        // relaunch that macOS requires never gets offered.
        permissions.refresh()
        guard permissions.state != .granted else {
            needsRelaunch = permissions.needsRelaunchAfterGrant
            return
        }

        permissions.beginProbing()
        Task { [weak self] in
            // The coordinator stops its own probe the moment it succeeds, so this watches
            // the state rather than the probe, and checks once more after it stops.
            while let self {
                if permissions.state == .granted {
                    needsRelaunch = permissions.needsRelaunchAfterGrant
                    return
                }
                guard permissions.isProbing else {
                    needsRelaunch = permissions.needsRelaunchAfterGrant
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopWatchingForGrant() {
        permissions.endProbing()
    }

    /// Restarts so the new grant takes effect (docs/04 §4.1).
    func relaunch() {
        settings.hasCompletedOnboarding = true
        Task {
            do {
                try await relauncher.relaunchForNewGrant()
            } catch {
                logger.error("Could not relaunch: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Defaults

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            logger.error("Could not set the login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveFolderPath = url.path
    }
}
