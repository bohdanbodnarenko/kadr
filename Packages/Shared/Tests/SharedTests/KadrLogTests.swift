import Testing
@testable import Shared

@Suite("KadrLog")
struct KadrLogTests {
    @Test("Subsystem matches the bundle identifier reserved in docs/00")
    func subsystem() {
        #expect(KadrLog.subsystem == "app.kadr.Kadr")
    }

    @Test("Category raw values are stable log identifiers")
    func categoryRawValues() {
        let expected = ["app", "hotkeys", "settings", "overlay", "capture", "recording", "history"]
        #expect(KadrLog.Category.allCases.map(\.rawValue) == expected)
    }

    @Test("Every category can open and close a signpost interval")
    func signpostIntervalsWork() {
        for category in KadrLog.Category.allCases {
            let signposter = KadrLog.signposter(category)
            let state = signposter.beginInterval("probe")
            signposter.endInterval("probe", state)
        }
        #expect(KadrLog.Category.allCases.count == 7)
    }
}
