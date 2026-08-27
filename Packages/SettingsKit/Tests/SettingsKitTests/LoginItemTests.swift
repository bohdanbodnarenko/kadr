import ServiceManagement
import Testing
@testable import SettingsKit

@Suite("Login item state")
struct LoginItemStateTests {
    @Test("SMAppService statuses map to the states the General pane shows", arguments: [
        (SMAppService.Status.enabled, LoginItemState.enabled, true),
        (SMAppService.Status.notRegistered, LoginItemState.disabled, false),
        (SMAppService.Status.requiresApproval, LoginItemState.requiresApproval, true),
        (SMAppService.Status.notFound, LoginItemState.notFound, false)
    ])
    func statusMapping(status: SMAppService.Status, expected: LoginItemState, isOn: Bool) {
        let state = LoginItemState(status: status)
        #expect(state == expected)
        #expect(state.isOn == isOn)
    }

    @Test("Only the states the user must act on carry an explanation")
    func explanations() {
        #expect(LoginItemState.enabled.explanation == nil)
        #expect(LoginItemState.disabled.explanation == nil)
        #expect(LoginItemState.requiresApproval.explanation != nil)
        #expect(LoginItemState.notFound.explanation != nil)
    }
}
