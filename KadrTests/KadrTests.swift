import Foundation
import Testing
@testable import Kadr

/// Scaffolding-level checks on the agent bundle itself (milestone M0.1).
/// These run in-process in the host app, so they assert on `Bundle.main`.
@Suite("Kadr agent bundle")
struct KadrTests {
    @Test("The agent is an LSUIElement: no Dock icon, no main menu (docs/04 §3.1)")
    func agentIsAccessoryApp() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    }

    @Test("Bundle identifier is the one reserved in docs/00")
    func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.bohdanbodnarenko.kadr")
    }
}
