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
    /// Drives the “you can finish setup later” explanation Escape has to pass through
    /// when capture is not going to work yet (docs/14 UX-07).
    var showsCloseExplanation = false

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

    /// Whether leaving now needs a word first (docs/14 UX-07).
    ///
    /// Only when the required grant is missing. Somebody who has already allowed screen
    /// capture has finished the part that matters, and an explanation would be noise.
    var requiresCloseExplanation: Bool {
        appPermissions.status(.screen) != .allowed
    }

    /// Escape, the window's close button and Skip for Now all arrive here.
    ///
    /// Escape is *not* wired to Skip as a cancel action: on a three-step wizard with a
    /// Back button present, a key that looks like “go back” must not silently end setup
    /// (docs/14 UX-07).
    func requestClose() {
        if requiresCloseExplanation {
            showsCloseExplanation = true
        } else {
            skip()
        }
    }

    func confirmClose() {
        showsCloseExplanation = false
        skip()
    }

    func cancelClose() {
        showsCloseExplanation = false
    }

    /// The primary button's title. Stable position, state-dependent words (docs/14 UX-07).
    var primaryActionTitle: String {
        switch step {
        case .welcome:
            "Get Started"
        case .permissions:
            appPermissions.status(.screen) == .allowed ? "Continue" : "Continue Without Screen Access"
        case .defaults:
            "Done"
        }
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
    /// Releases what the next instance needs before it starts — the CLI's port and the
    /// global hotkeys — so it does not find them taken (docs/17 T-SH-3).
    @ObservationIgnored var prepareForRelaunch: () -> Void = {}
    /// Takes them back when the new instance could not be started.
    @ObservationIgnored var relaunchFailed: () -> Void = {}

    func relaunch() {
        settings.resumeOnboardingAtPermissions = true
        prepareForRelaunch()
        Task {
            do {
                try await relauncher.relaunchForNewGrant()
            } catch {
                logger.error("Could not relaunch: \(error.localizedDescription, privacy: .public)")
                relaunchFailed()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            FailurePresenter.report(
                enabled ? "Kadr could not add itself to your login items." : "Kadr could not remove itself from your login items.",
                detail: error.localizedDescription,
                logger: logger
            )
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

    /// Opens the sample in the editor and leaves setup exactly where it was.
    ///
    /// It used to call `finish()` first, which meant trying the editor silently accepted
    /// whatever defaults happened to be on screen and marked setup complete. Closing the
    /// editor now returns to this step with those choices still unmade (docs/14 UX-08B).
    func openPracticeImage() {
        practiceError = nil
        do {
            let url = try OnboardingPracticeImage.makeWorkingCopy()
            onOpenPractice?(url)
        } catch {
            practiceError = "Couldn’t prepare the sample. Check that this Mac has free space, then try again."
            logger.error("Practice image failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The explicit version, for somebody who is done with setup and wants the editor.
    func finishAndOpenPracticeImage() {
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
