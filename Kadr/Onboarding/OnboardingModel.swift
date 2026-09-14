import AppKit
import CaptureCore
import Foundation
import os
import SettingsKit
import Shared

/// The three onboarding screens (docs/03 §8.2).
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case permissions
    case defaults

    var title: String {
        switch self {
        case .welcome: "Welcome to Kadr"
        case .permissions: "Set up permissions"
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
    @ObservationIgnored let appPermissions: AppPermissionTracker
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let loginItem: LoginItemController
    @ObservationIgnored private let relauncher: RelaunchHelper
    @ObservationIgnored private let logger = KadrLog.logger(.app)

    var step: OnboardingStep = .welcome
    /// Set when the grant arrived mid-session and the app has to restart to use it.
    private(set) var needsRelaunch = false
    var practiceError: String?

    /// Called when the user finishes or skips.
    var onFinish: (() -> Void)?
    /// Opens a practice PNG in the editor. Optional so tests do not launch one.
    var onOpenPractice: ((URL) -> Void)?

    init(
        permissions: PermissionCoordinator,
        settings: AppSettings,
        loginItem: LoginItemController,
        appPermissions: AppPermissionTracker? = nil,
        relauncher: RelaunchHelper = RelaunchHelper()
    ) {
        self.permissions = permissions
        self.settings = settings
        self.loginItem = loginItem
        self.relauncher = relauncher
        self.appPermissions = appPermissions ?? AppPermissionTracker(
            screen: permissions,
            settings: settings,
            resumesOnboarding: true
        )
        if settings.resumeOnboardingAtPermissions {
            step = .permissions
        }
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

    var canGoBack: Bool {
        step != .welcome
    }

    func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
        syncPermissionWatching()
    }

    func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = next
        syncPermissionWatching()
    }

    func skip() {
        finish()
    }

    func finish() {
        permissions.endProbing()
        settings.resumeOnboardingAtPermissions = false
        settings.hasCompletedOnboarding = true
        onFinish?()
    }

    /// Asks macOS for one grant. Screen Recording still goes through the coordinator
    /// so the relaunch flag stays accurate.
    func request(_ permission: AppPermission) {
        if permission == .screen {
            startWatchingForGrant()
        }
        Task { await appPermissions.request(permission) }
    }

    func openSystemSettings(_ permission: AppPermission) {
        if permission == .screen {
            startWatchingForGrant()
        }
        appPermissions.openSettings(permission)
    }

    func refreshPermissions() {
        permissions.refresh()
        appPermissions.refresh()
        needsRelaunch = permissions.needsRelaunchAfterGrant
    }

    /// Watches for the grant appearing while the user is in System Settings.
    ///
    /// macOS sends no notification when the switch is flipped, so this is the one place
    /// in the app that polls — and it stops the moment the answer arrives or the screen
    /// goes away (PRD §8: zero timers at idle). Returning to the app also refreshes,
    /// which is how Allow flips to Allowed without waiting for the probe tick.
    func startWatchingForGrant() {
        permissions.refresh()
        appPermissions.refresh()
        guard permissions.state != .granted else {
            needsRelaunch = permissions.needsRelaunchAfterGrant
            return
        }

        permissions.beginProbing()
        Task { [weak self] in
            while let self {
                if permissions.state == .granted {
                    needsRelaunch = permissions.needsRelaunchAfterGrant
                    appPermissions.refresh()
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
    ///
    /// Setup is *not* marked complete: the resume flag brings the user back to
    /// Permissions so they see Allowed and can finish the last screen.
    func relaunch() {
        settings.resumeOnboardingAtPermissions = true
        Task {
            do {
                try await relauncher.relaunchForNewGrant()
            } catch {
                logger.error("Could not relaunch: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

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

    func openPracticeImage() {
        practiceError = nil
        do {
            let url = try OnboardingPracticeImage.makeWorkingCopy()
            finish()
            onOpenPractice?(url)
        } catch {
            practiceError = "Couldn’t prepare the sample. Check that this Mac has free space, then try again."
            logger.error("Practice image failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncPermissionWatching() {
        if step == .permissions {
            startWatchingForGrant()
        } else {
            permissions.endProbing()
        }
    }
}
