import AppKit
import CaptureCore
import Foundation
import SettingsKit
import Testing
@testable import Kadr

@MainActor
@Suite("UX excellence (docs/14)")
struct UXExcellenceTests {
    // MARK: - UX-06

    @Test("Only one permission row carries relaunch guidance")
    func relaunchGuidanceOwner() {
        let tracker = AppPermissionTracker(
            sampling: ScriptablePermissionSampling(statuses: [
                .screen: .notEnabled,
                .accessibility: .notEnabled,
                .inputMonitoring: .notEnabled
            ]),
            resumesOnboarding: true
        )
        tracker.openSettings(.screen)
        tracker.openSettings(.accessibility)

        #expect(tracker.relaunchGuidanceOwner == .screen)
    }

    @Test("Recovery text is one sentence and mentions relaunch only when asked")
    func recoveryCopy() {
        let withRelaunch = AppPermission.screen.recovery(
            status: .notEnabled,
            attempted: true,
            includesRelaunchGuidance: true
        )
        let withoutRelaunch = AppPermission.accessibility.recovery(
            status: .notEnabled,
            attempted: true,
            includesRelaunchGuidance: false
        )

        #expect(withRelaunch?.contains("next time Kadr opens") == true)
        #expect(withoutRelaunch?.contains("next time Kadr opens") == false)
        #expect(
            AppPermission.screen.recovery(
                status: .allowed,
                attempted: false,
                includesRelaunchGuidance: true
            ) == nil
        )
    }

    // MARK: - UX-07

    @Test("Escape needs an explanation when screen access is missing")
    func closeNeedsExplanationWithoutScreenAccess() {
        let fixture = makeOnboardingModel(screenGranted: false)
        #expect(fixture.model.requiresCloseExplanation)
        fixture.model.requestClose()
        #expect(fixture.model.showsCloseExplanation)
    }

    @Test("Escape can finish immediately when screen access is already allowed")
    func closeSkipsExplanationWithScreenAccess() {
        let fixture = makeOnboardingModel(screenGranted: true)
        var finished = false
        fixture.model.onFinish = { finished = true }

        #expect(!fixture.model.requiresCloseExplanation)
        fixture.model.requestClose()

        #expect(finished)
        #expect(fixture.settings.hasCompletedOnboarding)
        #expect(!fixture.model.showsCloseExplanation)
    }

    @Test("The permission step primary button reflects screen access")
    func permissionPrimaryTitle() {
        let denied = makeOnboardingModel(
            screenGranted: false,
            appPermissions: AppPermissionTracker(
                sampling: ScriptablePermissionSampling(statuses: [.screen: .notEnabled])
            )
        )
        denied.model.advance()
        #expect(denied.model.step == .permissions)
        #expect(denied.model.primaryActionTitle == "Continue Without Screen Access")

        let allowed = makeOnboardingModel(
            screenGranted: true,
            appPermissions: AppPermissionTracker(
                sampling: ScriptablePermissionSampling(statuses: [.screen: .allowed])
            )
        )
        allowed.model.advance()
        #expect(allowed.model.primaryActionTitle == "Continue")
    }

    // MARK: - UX-08B

    @Test("Trying the practice image does not finish onboarding")
    func practiceImagePreservesSetup() {
        let fixture = makeOnboardingModel(screenGranted: false)
        fixture.model.advance()
        fixture.model.advance()
        #expect(fixture.model.step == .defaults)

        var opened: URL?
        fixture.model.onOpenPractice = { opened = $0 }
        fixture.model.openPracticeImage()

        #expect(opened != nil)
        #expect(!fixture.settings.hasCompletedOnboarding)
        #expect(fixture.model.step == .defaults)
    }

    @Test("Finish setup and try the editor marks onboarding complete")
    func finishAndPracticeCompletesSetup() {
        let fixture = makeOnboardingModel(screenGranted: false)
        fixture.model.advance()
        fixture.model.advance()
        var finished = false
        fixture.model.onFinish = { finished = true }
        fixture.model.onOpenPractice = { _ in }

        fixture.model.finishAndOpenPracticeImage()

        #expect(finished)
        #expect(fixture.settings.hasCompletedOnboarding)
    }

    // MARK: - UX-09

    @Test("Settings uses one tested minimum size everywhere")
    func settingsMinimumGeometry() {
        #expect(SettingsWindowGeometry.minimumWidth == 700)
        #expect(SettingsWindowGeometry.minimumHeight == 540)
        #expect(SettingsWindowGeometry.minimumSize == NSSize(width: 700, height: 540))
    }

    @Test("Help covers every topic")
    func helpTopics() {
        #expect(KadrHelpTopic.allCases.count >= 6)
    }

    // MARK: - UX-11

    @Test("Recording overlay scales map to readable percent units")
    func recordingPercentBindings() {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        let settings = AppSettings(store: store)

        settings.recordingClickScale = 1.25
        settings.recordingKeystrokeScale = 0.9
        settings.recordingWebcamSize = 0.22

        #expect(Int((settings.recordingClickScale * 100).rounded()) == 125)
        #expect(Int((settings.recordingKeystrokeScale * 100).rounded()) == 90)
        #expect(Int((settings.recordingWebcamSize * 100).rounded()) == 22)
    }

    // MARK: - UX-12

    @Test("A full action row refuses another action of the same kind")
    func cardLayoutRefusesOverflow() {
        var layout = CardLayout()
        let screenshotActions = CardAction.allCases.filter { $0.applies(to: .screenshot) }
        for action in screenshotActions {
            layout.place(action, in: .column)
        }
        let before = layout.placedActions
        layout.place(.copy, in: .topLeading)
        #expect(layout.placedActions == before.union([.copy]))
    }

    // MARK: - Helpers

    private func makeOnboardingModel(
        screenGranted: Bool,
        appPermissions: AppPermissionTracker? = nil
    ) -> (model: OnboardingModel, settings: AppSettings) {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        let settings = AppSettings(store: store)
        let access = UXFakeScreenAccess(granted: screenGranted)
        let tracker = appPermissions ?? AppPermissionTracker(
            sampling: ScriptablePermissionSampling(statuses: [
                .screen: screenGranted ? .allowed : .notEnabled
            ])
        )
        let model = OnboardingModel(
            permissions: PermissionCoordinator(access: access),
            settings: settings,
            loginItem: LoginItemController(),
            appPermissions: tracker
        )
        return (model, settings)
    }
}

/// Scriptable TCC answers for onboarding and permission tests.
private struct ScriptablePermissionSampling: AppPermissionSampling {
    var statuses: [AppPermission: AppPermissionStatus]

    func status(of permission: AppPermission) -> AppPermissionStatus {
        statuses[permission] ?? .notEnabled
    }

    func request(_ permission: AppPermission) async {}
}

/// Screen-recording access stub.
private final class UXFakeScreenAccess: ScreenRecordingAccessProviding, @unchecked Sendable {
    var granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }

    func preflight() -> Bool {
        granted
    }

    @discardableResult
    func request() -> Bool {
        granted
    }

    func probe() async -> Bool {
        granted
    }
}
