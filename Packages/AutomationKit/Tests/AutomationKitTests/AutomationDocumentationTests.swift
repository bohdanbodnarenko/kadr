import Foundation
import Testing
@testable import AutomationKit

/// docs/AUTOMATION.md is the automation contract users read (docs/06 M19: "document
/// every verb"). A verb that exists but is not written down is a verb nobody can use, and
/// an alias that is documented but no longer resolves is worse — so the document and the
/// code are checked against each other rather than kept in step by hand.
@Suite("Automation documentation")
struct AutomationDocumentationTests {
    /// Walks up from this file to the repo root and reads the automation reference.
    private func documentation() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("docs/AUTOMATION.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw DocumentationError.notFound
    }

    private enum DocumentationError: Error {
        case notFound
    }

    @Test("Every verb is documented", arguments: AutomationVerb.allCases)
    func everyVerbIsDocumented(verb: AutomationVerb) throws {
        let text = try documentation()
        #expect(text.contains("`\(verb.rawValue)`"), "docs/AUTOMATION.md does not mention \(verb.rawValue)")
    }

    @Test("Every alias is documented", arguments: Array(AutomationVerb.aliases.keys))
    func everyAliasIsDocumented(alias: String) throws {
        let text = try documentation()
        #expect(text.contains("`\(alias)`"), "docs/AUTOMATION.md does not mention the alias \(alias)")
    }

    @Test("Every parameter a verb takes is documented", arguments: AutomationParameter.allCases)
    func everyParameterIsDocumented(parameter: AutomationParameter) throws {
        let text = try documentation()
        #expect(text.contains(parameter.rawValue), "docs/AUTOMATION.md does not mention \(parameter.rawValue)")
    }

    @Test("Every exit code is documented", arguments: [0, 1, 2, 3, 64])
    func everyExitCodeIsDocumented(code: Int) throws {
        let text = try documentation()
        #expect(text.contains("| \(code) |"), "docs/AUTOMATION.md does not list exit code \(code)")
    }
}
