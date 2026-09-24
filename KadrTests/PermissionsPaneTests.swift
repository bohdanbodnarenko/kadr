import Testing
@testable import Kadr

/// Settings ▸ Permissions offers Quit & Reopen only for a grant that arrived while it
/// was open and that macOS applies to a new process (docs/17 T-SH-4).
@MainActor
@Suite("Permissions pane reopen")
struct PermissionsPaneTests {
    @Test("Which new grants need a reopen", arguments: [
        (AppPermission.screen, AppPermissionStatus.notEnabled, AppPermissionStatus.allowed, true),
        (.accessibility, .denied, .allowed, true),
        (.inputMonitoring, .allowed, .allowed, false),
        (.microphone, .notEnabled, .allowed, false),
        (.screen, .notEnabled, .denied, false)
    ])
    func reopen(
        permission: AppPermission,
        before: AppPermissionStatus,
        now: AppPermissionStatus,
        expected: Bool
    ) {
        let needed = PermissionsPane.grantsNeedingReopen(before: [permission: before], now: [permission: now])
        #expect(needed.contains(permission) == expected)
    }

    @Test("Onboarding names the menu row that exists")
    func finishSetupTitle() {
        #expect(StatusItemController.finishSetupTitle == "Finish Setup…")
    }
}
