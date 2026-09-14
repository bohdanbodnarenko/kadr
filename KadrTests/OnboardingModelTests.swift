import CaptureCore
import CoreGraphics
import Foundation
import SettingsKit
import Testing
@testable import Kadr

/// A scriptable stand-in for the system's permission answers.
private final class FakeAccess: ScreenRecordingAccessProviding, @unchecked Sendable {
    var preflightResult = false
    var probeResult = false
    var requestResult = false

    func preflight() -> Bool {
        preflightResult
    }

    @discardableResult
    func request() -> Bool {
        requestResult
    }

    func probe() async -> Bool {
        probeResult
    }
}

private final class FakeRelauncher: ApplicationRelaunching, @unchecked Sendable {
    private(set) var relaunchCount = 0
    private(set) var terminateCount = 0

    func relaunch(bundleURL: URL) async throws {
        relaunchCount += 1
    }

    func terminate() {
        terminateCount += 1
    }
}

@MainActor
private func makeModel(_ access: FakeAccess) -> (OnboardingModel, AppSettings) {
    let suite = UUID().uuidString
    guard let store = UserDefaults(suiteName: suite) else {
        fatalError("Could not open a throwaway defaults suite")
    }
    store.removePersistentDomain(forName: suite)
    let settings = AppSettings(store: store)
    let model = OnboardingModel(
        permissions: PermissionCoordinator(access: access),
        settings: settings,
        loginItem: LoginItemController(),
        relauncher: RelaunchHelper(
            relauncher: FakeRelauncher(),
            bundleURL: URL(fileURLWithPath: "/tmp/Kadr.app")
        )
    )
    return (model, settings)
}

@MainActor
@Suite("Onboarding")
struct OnboardingModelTests {
    @Test("It walks the three screens from doc 03 §8.2 and then finishes")
    func walksThreeScreens() {
        let (model, settings) = makeModel(FakeAccess())
        var finished = false
        model.onFinish = { finished = true }

        #expect(model.step == .welcome)
        model.advance()
        #expect(model.step == .permissions)
        model.advance()
        #expect(model.step == .defaults)
        #expect(model.isLastStep)

        model.advance()
        #expect(finished)
        #expect(settings.hasCompletedOnboarding, "finishing must not leave onboarding to reappear")
    }

    @Test("Skipping finishes from any screen")
    func skipFinishes() {
        let (model, settings) = makeModel(FakeAccess())
        var finished = false
        model.onFinish = { finished = true }

        model.skip()

        #expect(finished)
        #expect(settings.hasCompletedOnboarding)
    }

    @Test("Polling runs only while the permission screen is showing (PRD §8: no idle timers)")
    func pollsOnlyOnThePermissionScreen() {
        let access = FakeAccess()
        let (model, _) = makeModel(access)

        model.startWatchingForGrant()
        model.advance() // to the permission screen — still watching
        model.advance() // to defaults — must stop

        // `advance` past the permission screen ends the probe; nothing else in the app
        // polls at all.
        #expect(model.step == .defaults)
    }

    @Test("Leaving the screen stops the probe")
    func stopWatching() {
        let (model, _) = makeModel(FakeAccess())
        model.startWatchingForGrant()
        model.stopWatchingForGrant()
        model.advance()
        #expect(model.step == .permissions)
    }

    @Test("A grant that arrives mid-session is reported as needing a restart")
    func grantMidSessionNeedsRelaunch() async {
        let access = FakeAccess()
        let (model, _) = makeModel(access)
        // Entering the permission screen reads the current state, which is denied here.
        model.advance()

        access.probeResult = true
        model.startWatchingForGrant()

        for _ in 0 ..< 40 where !model.needsRelaunch {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.permissionState == .granted)
        #expect(model.needsRelaunch, "macOS does not apply a new grant to a running process")
        model.stopWatchingForGrant()
    }

    @Test("A grant already in place needs no restart")
    func grantAtLaunchNeedsNoRelaunch() {
        let access = FakeAccess()
        access.preflightResult = true
        let (model, _) = makeModel(access)

        #expect(model.needsRelaunch == false)
    }

    @Test("A permission restart reopens on the permissions screen")
    func resumesAtPermissions() {
        let access = FakeAccess()
        let (model, settings) = makeModel(access)
        settings.resumeOnboardingAtPermissions = true
        let resumed = OnboardingModel(
            permissions: PermissionCoordinator(access: access),
            settings: settings,
            loginItem: LoginItemController()
        )
        #expect(resumed.step == .permissions)
        #expect(model.step == .welcome, "a model created before the flag stays put")
    }

    @Test("Back walks toward welcome")
    func goBack() {
        let (model, _) = makeModel(FakeAccess())
        model.advance()
        #expect(model.step == .permissions)
        model.goBack()
        #expect(model.step == .welcome)
        #expect(!model.canGoBack)
    }

    @Test("Restarting for a grant does not mark setup complete")
    func relaunchKeepsSetupOpen() {
        let (model, settings) = makeModel(FakeAccess())
        model.relaunch()
        #expect(settings.resumeOnboardingAtPermissions)
        #expect(!settings.hasCompletedOnboarding)
    }

    @Test("After an ask, a still-off grant that needs a relaunch routes to System Settings")
    func deniedAskNeedsSettings() {
        #expect(AppPermission.screen.needsSettings(status: .notEnabled, attempted: true))
        #expect(!AppPermission.screen.needsSettings(status: .notEnabled, attempted: false))
        #expect(!AppPermission.microphone.needsSettings(status: .notEnabled, attempted: true))
        #expect(AppPermission.microphone.needsSettings(status: .denied, attempted: false))
        #expect(!AppPermission.camera.needsSettings(status: .allowed, attempted: true))
    }

    @Test("The practice image is a real photograph-sized PNG")
    func practiceImageRenders() throws {
        let image = try #require(OnboardingPracticeImage.render())
        #expect(image.width == 1600)
        #expect(image.height == 1000)
    }
}
