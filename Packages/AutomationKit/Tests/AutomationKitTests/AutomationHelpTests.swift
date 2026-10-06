import Testing
@testable import AutomationKit

/// docs/18 OUT-14: `kadr help <command>` lists exactly the options the parser accepts.
@Suite("Automation help")
struct AutomationHelpTests {
    @Test("Every verb's help names it and each of its options", arguments: AutomationVerb.allCases)
    func listsOptions(verb: AutomationVerb) {
        let text = AutomationHelp.text(for: verb)
        #expect(text.hasPrefix("kadr \(verb.rawValue) — "))
        for parameter in verb.parameters {
            #expect(text.contains("--\(parameter.rawValue)"))
        }
        if verb.parameters.isEmpty {
            #expect(text.contains("takes no options"))
        }
    }

    @Test("Every option has a description")
    func everyParameterDescribed() {
        for parameter in AutomationParameter.allCases {
            #expect(!parameter.summary.isEmpty)
        }
    }
}
