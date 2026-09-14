import AppKit
import CaptureCore
import Foundation
import os
import SettingsKit
import Shared

/// Live status for every grant onboarding and Settings show (docs/03 §8.2).
///
/// Screen Recording still goes through `PermissionCoordinator` so the relaunch
/// machine stays in one place. The other grants are boolean (or AV status) reads
/// that only run when a permissions UI is on screen — never as an idle timer.
@MainActor
@Observable
final class AppPermissionTracker {
    @ObservationIgnored private let sampling: any AppPermissionSampling
    @ObservationIgnored private let screen: PermissionCoordinator?
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private let resumesOnboarding: Bool
    @ObservationIgnored private let logger = KadrLog.logger(.app)

    private(set) var statuses: [AppPermission: AppPermissionStatus] = [:]
    private(set) var attempted: Set<AppPermission> = []
    private(set) var requesting: AppPermission?
    private(set) var settingsError: String?
    private(set) var settingsErrorPermission: AppPermission?

    init(
        sampling: any AppPermissionSampling = SystemAppPermissionSampling(),
        screen: PermissionCoordinator? = nil,
        settings: AppSettings? = nil,
        resumesOnboarding: Bool = false
    ) {
        self.sampling = sampling
        self.screen = screen
        self.settings = settings
        self.resumesOnboarding = resumesOnboarding
        refresh()
    }

    func status(_ permission: AppPermission) -> AppPermissionStatus {
        statuses[permission] ?? .notEnabled
    }

    /// The one row that carries the “reopen Kadr” caveat (docs/14 UX-06).
    ///
    /// It is a fact about macOS, not about the grant, so the first row that needs it says
    /// it and the rest stay quiet — otherwise three rows each look separately broken.
    var relaunchGuidanceOwner: AppPermission? {
        AppPermission.allCases.first { permission in
            permission.mayNeedRelaunch
                && permission.needsSettings(
                    status: status(permission),
                    attempted: attempted.contains(permission)
                )
        }
    }

    func refresh() {
        var next: [AppPermission: AppPermissionStatus] = [:]
        for permission in AppPermission.allCases {
            next[permission] = sampling.status(of: permission)
        }
        statuses = next
    }

    func request(_ permission: AppPermission) async {
        guard requesting == nil, status(permission) != .allowed, status(permission) != .restricted else {
            return
        }
        refresh()
        guard status(permission) != .allowed, status(permission) != .restricted else { return }
        if permission.needsSettings(status: status(permission), attempted: attempted.contains(permission)) {
            openSettings(permission)
            return
        }
        requesting = permission
        attempted.insert(permission)
        settingsError = nil
        settingsErrorPermission = nil
        rememberResumeIfNeeded(for: permission)
        defer {
            requesting = nil
            refresh()
        }
        if permission == .screen, let screen {
            screen.requestAccess()
        } else {
            await sampling.request(permission)
        }
    }

    func openSettings(_ permission: AppPermission) {
        guard requesting == nil, status(permission) != .restricted else { return }
        rememberResumeIfNeeded(for: permission)
        attempted.insert(permission)
        let opened = NSWorkspace.shared.open(permission.settingsURL)
        settingsError = opened
            ? nil
            : "Couldn’t open System Settings. Try again, or open Privacy & Security → \(permission.title)."
        settingsErrorPermission = settingsError == nil ? nil : permission
        if !opened {
            logger.error("Could not open \(permission.title, privacy: .public) settings")
        }
    }

    private func rememberResumeIfNeeded(for permission: AppPermission) {
        guard resumesOnboarding, permission.mayNeedRelaunch else { return }
        settings?.resumeOnboardingAtPermissions = true
    }
}
