import Foundation
import ScreenCaptureKit
import Testing
@testable import CaptureCore

/// A scriptable stand-in for CoreGraphics and ScreenCaptureKit.
private final class FakeAccess: ScreenRecordingAccessProviding, @unchecked Sendable {
    var preflightResult = false
    var requestResult = false
    var probeResult = false
    private(set) var requestCount = 0
    private(set) var probeCount = 0

    func preflight() -> Bool {
        preflightResult
    }

    @discardableResult
    func request() -> Bool {
        requestCount += 1
        return requestResult
    }

    func probe() async -> Bool {
        probeCount += 1
        return probeResult
    }
}

private func scError(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamErrorDomain, code: code.rawValue, userInfo: nil)
}

@MainActor
@Suite("Permission state machine")
struct PermissionCoordinatorTests {
    @Test("A fresh coordinator has not asked anything yet")
    func startsUnknown() {
        let coordinator = PermissionCoordinator(access: FakeAccess())
        #expect(coordinator.state == .unknown)
        #expect(coordinator.isProbing == false)
        #expect(coordinator.needsRelaunchAfterGrant == false)
    }

    @Test("Preflight decides the launch state without prompting")
    func refreshReadsPreflight() {
        let access = FakeAccess()
        let coordinator = PermissionCoordinator(access: access)

        access.preflightResult = false
        #expect(coordinator.refresh() == .denied)

        access.preflightResult = true
        #expect(coordinator.refresh() == .granted)
        #expect(access.requestCount == 0)
    }

    @Test("A grant present at launch needs no relaunch")
    func grantedAtLaunchNeedsNoRelaunch() {
        let access = FakeAccess()
        access.preflightResult = true
        let coordinator = PermissionCoordinator(access: access)
        coordinator.refresh()

        #expect(coordinator.state == .granted)
        #expect(coordinator.needsRelaunchAfterGrant == false)
    }

    @Test("A grant that arrives while running requires a relaunch (docs/04 §4.1)")
    func grantMidSessionNeedsRelaunch() async {
        let access = FakeAccess()
        let coordinator = PermissionCoordinator(access: access)
        coordinator.refresh() // denied

        access.probeResult = true
        coordinator.beginProbing(every: .milliseconds(1))
        while coordinator.state != .granted {
            await Task.yield()
        }

        #expect(coordinator.state == .granted)
        #expect(coordinator.needsRelaunchAfterGrant)
        #expect(coordinator.isProbing == false, "the probe must stop the moment it succeeds")
    }

    @Test("The probe loop stops when onboarding goes away — it is the app's only poll")
    func probeStops() async {
        let access = FakeAccess()
        let coordinator = PermissionCoordinator(access: access)
        coordinator.beginProbing(every: .milliseconds(1))
        #expect(coordinator.isProbing)

        coordinator.endProbing()
        #expect(coordinator.isProbing == false)

        let countAfterStop = access.probeCount
        try? await Task.sleep(for: .milliseconds(20))
        #expect(access.probeCount <= countAfterStop + 1, "probing continued after it was stopped")
    }

    @Test("Starting the probe twice does not start two loops")
    func probeIsIdempotent() {
        let coordinator = PermissionCoordinator(access: FakeAccess())
        coordinator.beginProbing(every: .milliseconds(1))
        coordinator.beginProbing(every: .milliseconds(1))
        coordinator.endProbing()
        #expect(coordinator.isProbing == false)
    }

    @Test("A declined capture moves a granted app to revoked")
    func revocation() {
        let access = FakeAccess()
        access.preflightResult = true
        let coordinator = PermissionCoordinator(access: access)
        coordinator.refresh()

        coordinator.noteCaptureFailure(scError(.userDeclined))
        #expect(coordinator.state == .revoked)
        #expect(coordinator.state.needsUserAction)
        #expect(coordinator.state.allowsCapture == false)
    }

    @Test("A non-permission failure leaves the state alone")
    func unrelatedFailureIsIgnored() {
        let access = FakeAccess()
        access.preflightResult = true
        let coordinator = PermissionCoordinator(access: access)
        coordinator.refresh()

        coordinator.noteCaptureFailure(scError(.noWindowList))
        #expect(coordinator.state == .granted)
    }

    @Test("A successful capture proves the grant is live")
    func successRestoresGranted() {
        let access = FakeAccess()
        let coordinator = PermissionCoordinator(access: access)
        coordinator.refresh() // denied
        coordinator.noteCaptureSuccess()

        #expect(coordinator.state == .granted)
    }

    @Test("Refresh does not overwrite a revoked state with a plain denial")
    func refreshKeepsRevoked() {
        let access = FakeAccess()
        access.preflightResult = true
        let coordinator = PermissionCoordinator(access: access)
        coordinator.refresh()
        coordinator.noteCaptureFailure(scError(.userDeclined))

        access.preflightResult = false
        #expect(coordinator.refresh() == .revoked, "revoked is more specific than denied and must survive")
    }

    @Test("Requesting access prompts once and records a grant")
    func requestAccess() {
        let access = FakeAccess()
        access.requestResult = true
        let coordinator = PermissionCoordinator(access: access)

        #expect(coordinator.requestAccess())
        #expect(access.requestCount == 1)
        #expect(coordinator.state == .granted)
    }
}
