import Foundation
import Shared
import Testing
@testable import AutomationKit

/// The verb/parameter grammar shared by the URL scheme and the CLI (docs/03 §8.4).
///
/// Table-driven and exhaustive on purpose: the parser is the one piece of the automation
/// layer that can be wrong silently. A verb that quietly captures the wrong rectangle, or
/// a typo that is ignored rather than reported, is a bug the user finds days later in a
/// screenshot they already sent (CLAUDE.md rule 9).
@Suite("Automation parser")
struct AutomationParserTests {
    // MARK: - Every verb round-trips

    @Test("Every canonical verb parses from its own URL", arguments: AutomationVerb.allCases)
    func everyVerbParsesFromURL(verb: AutomationVerb) throws {
        // The two verbs that name a file cannot be parsed without one.
        let query = verb.parameters.contains(.path) ? "?path=/tmp/shot.png" : ""
        let url = try #require(URL(string: "kadr://\(verb.rawValue)\(query)"))
        let command = try AutomationParser.command(from: url)
        #expect(command.verb == verb)
    }

    @Test("Every canonical verb parses from a command line", arguments: AutomationVerb.allCases)
    func everyVerbParsesFromArguments(verb: AutomationVerb) throws {
        let arguments = verb.parameters.contains(.path)
            ? [verb.rawValue, "--path", "/tmp/shot.png"]
            : [verb.rawValue]
        let invocation = try AutomationParser.invocation(arguments: arguments)
        #expect(invocation.command.verb == verb)
    }

    @Test("Every alias resolves to a canonical verb", arguments: Array(AutomationVerb.aliases.keys))
    func everyAliasResolves(alias: String) throws {
        let verb = try #require(AutomationVerb.canonical(for: alias))
        #expect(AutomationVerb.allCases.contains(verb))
    }

    @Test("Verbs and aliases are matched case-insensitively")
    func verbsAreCaseInsensitive() {
        #expect(AutomationVerb.canonical(for: "Capture-Area") == .captureArea)
        #expect(AutomationVerb.canonical(for: "SCROLLING-CAPTURE") == .captureScrolling)
        #expect(AutomationVerb.canonical(for: " capture-text ") == .captureText)
    }

    @Test("No alias shadows a canonical verb")
    func aliasesDoNotShadow() {
        for alias in AutomationVerb.aliases.keys {
            #expect(AutomationVerb(rawValue: alias) == nil, "\(alias) is also a canonical verb")
        }
    }

    // MARK: - The documented URL examples

    @Test("The URL scheme example from docs/03 §8.4 parses")
    func documentedExampleParses() throws {
        let url = try #require(URL(string: "kadr://capture-area?action=copy&x=10&y=20&w=300&h=200"))
        guard case let .captureArea(options) = try AutomationParser.command(from: url) else {
            Issue.record("expected capture-area")
            return
        }
        #expect(options.action == .copy)
        #expect(options.region == ScreenRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test("A verb in the path parses like a verb in the host")
    func pathVerbParses() throws {
        let url = try #require(URL(string: "kadr:capture-fullscreen"))
        #expect(try AutomationParser.command(from: url).verb == .captureFullscreen)
    }

    @Test("record-screen takes an fps")
    func recordScreenTakesFPS() throws {
        let url = try #require(URL(string: "kadr://record-screen?fps=30"))
        guard case let .recordScreen(options) = try AutomationParser.command(from: url) else {
            Issue.record("expected record-screen")
            return
        }
        #expect(options.frameRate == 30)
    }

    @Test("pin needs a file path, under any of its spellings", arguments: ["path", "filepath", "file"])
    func pinTakesAPath(parameter: String) throws {
        let url = try #require(URL(string: "kadr://pin?\(parameter)=/tmp/a.png"))
        guard case let .pin(target) = try AutomationParser.command(from: url) else {
            Issue.record("expected pin")
            return
        }
        #expect(target.path == "/tmp/a.png")
    }

    @Test("open-settings takes a tab", arguments: SettingsTab.allCases)
    func openSettingsTakesATab(tab: SettingsTab) throws {
        let url = try #require(URL(string: "kadr://open-settings?tab=\(tab.rawValue)"))
        #expect(try AutomationParser.command(from: url) == .openSettings(tab))
    }

    @Test("toggle-desktop-icons takes a state", arguments: ToggleState.allCases)
    func toggleDesktopIconsTakesAState(state: ToggleState) throws {
        let url = try #require(URL(string: "kadr://toggle-desktop-icons?state=\(state.rawValue)"))
        #expect(try AutomationParser.command(from: url) == .toggleDesktopIcons(state))
    }

    @Test("toggle-desktop-icons with no state flips it")
    func toggleDesktopIconsDefaultsToToggle() throws {
        let url = try #require(URL(string: "kadr://toggle-desktop-icons"))
        #expect(try AutomationParser.command(from: url) == .toggleDesktopIcons(.toggle))
    }

    // MARK: - CLI syntax

    @Test("Both --name value and --name=value are accepted")
    func bothFlagSpellingsWork() throws {
        let spaced = try AutomationParser.invocation(arguments: ["capture-area", "--action", "save"])
        let joined = try AutomationParser.invocation(arguments: ["capture-area", "--action=save"])
        #expect(spaced.command == joined.command)
        #expect(spaced.command == .captureArea(CaptureOptions(action: .save)))
    }

    @Test("A boolean parameter works as a bare flag and as a negation")
    func booleanFlags() throws {
        let on = try AutomationParser.invocation(arguments: ["capture-area", "--cursor"])
        let off = try AutomationParser.invocation(arguments: ["capture-area", "--no-cursor"])
        #expect(on.command == .captureArea(CaptureOptions(includesCursor: true)))
        #expect(off.command == .captureArea(CaptureOptions(includesCursor: false)))
    }

    @Test("--json, --no-wait and --timeout are CLI concerns, not verb parameters")
    func cliFlagsAreParsed() throws {
        let invocation = try AutomationParser.invocation(
            arguments: ["capture-area", "--json", "--no-wait", "--timeout", "5"]
        )
        #expect(invocation.wantsJSON)
        #expect(!invocation.waitsForResult)
        #expect(invocation.timeout == 5)
        #expect(invocation.command == .captureArea(.none))
    }

    @Test("Waiting is the default, and the wait scales with the verb")
    func waitingIsTheDefault() throws {
        let capture = try AutomationParser.invocation(arguments: ["capture-area"])
        #expect(capture.waitsForResult)
        #expect(!capture.wantsJSON)
        // A capture waits on the user…
        #expect(capture.timeout == AutomationParser.Invocation.defaultTimeout)
        // …opening a window does not.
        let settings = try AutomationParser.invocation(arguments: ["open-settings"])
        #expect(settings.timeout == AutomationParser.Invocation.quickTimeout)
        // An explicit --timeout always wins.
        let explicit = try AutomationParser.invocation(arguments: ["open-settings", "--timeout", "90"])
        #expect(explicit.timeout == 90)
    }

    @Test("A region can be given with short or long side names")
    func regionAcceptsShortNames() throws {
        let short = try AutomationParser.invocation(
            arguments: ["capture-area", "--x", "0", "--y", "0", "--w", "8", "--h", "6"]
        )
        let long = try AutomationParser.invocation(
            arguments: ["capture-area", "--x", "0", "--y", "0", "--width", "8", "--height", "6"]
        )
        #expect(short.command == long.command)
    }

    // MARK: - Failures

    @Test("An empty command line is a usage error")
    func emptyArgumentsFail() {
        #expect(throws: AutomationError.missingVerb) {
            try AutomationParser.invocation(arguments: [])
        }
        #expect(throws: AutomationError.missingVerb) {
            try AutomationParser.invocation(arguments: ["--json"])
        }
    }

    @Test("An unknown verb is reported by name")
    func unknownVerbFails() throws {
        let url = try #require(URL(string: "kadr://capture-moon"))
        #expect(throws: AutomationError.unknownVerb("capture-moon")) {
            try AutomationParser.command(from: url)
        }
    }

    @Test("A misspelled parameter is an error, never a silent no-op")
    func unknownParameterFails() throws {
        let url = try #require(URL(string: "kadr://capture-area?actoin=copy"))
        #expect(throws: AutomationError.unknownParameter(verb: "capture-area", name: "actoin")) {
            try AutomationParser.command(from: url)
        }
    }

    @Test("A parameter the verb does not take is an error")
    func parameterNotOnThisVerbFails() throws {
        let url = try #require(URL(string: "kadr://open-history?action=copy"))
        #expect(throws: AutomationError.unknownParameter(verb: "open-history", name: "action")) {
            try AutomationParser.command(from: url)
        }
    }

    @Test("Half a region is an error, not a guess", arguments: [
        ["--x", "0"],
        ["--x", "0", "--y", "0"],
        ["--x", "0", "--y", "0", "--w", "10"]
    ])
    func partialRegionFails(arguments: [String]) {
        #expect(throws: AutomationError.incompleteRegion) {
            try AutomationParser.invocation(arguments: ["capture-area"] + arguments)
        }
    }

    @Test("A zero-sized region is an error")
    func emptyRegionFails() {
        #expect(throws: (any Error).self) {
            try AutomationParser.invocation(
                arguments: ["capture-area", "--x", "0", "--y", "0", "--w", "0", "--h", "10"]
            )
        }
    }

    @Test("An unparseable value names the parameter and the value")
    func invalidValuesFail() {
        #expect(throws: AutomationError.invalidValue(name: "action", value: "email")) {
            try AutomationParser.invocation(arguments: ["capture-area", "--action", "email"])
        }
        #expect(throws: AutomationError.invalidValue(name: "fps", value: "999")) {
            try AutomationParser.invocation(arguments: ["record-screen", "--fps", "999"])
        }
        #expect(throws: AutomationError.invalidValue(name: "tab", value: "colours")) {
            try AutomationParser.invocation(arguments: ["open-settings", "--tab", "colours"])
        }
        #expect(throws: AutomationError.invalidValue(name: "delay", value: "-3")) {
            try AutomationParser.invocation(arguments: ["capture-area", "--delay", "-3"])
        }
    }

    @Test("A flag with no value is an error")
    func missingValueFails() {
        #expect(throws: AutomationError.missingValue(name: "action")) {
            try AutomationParser.invocation(arguments: ["capture-area", "--action"])
        }
    }

    @Test("pin without a path is an error")
    func pinWithoutPathFails() {
        #expect(throws: AutomationError.missingRequiredParameter(verb: "pin", name: "path")) {
            try AutomationParser.invocation(arguments: ["pin"])
        }
    }

    @Test("Another app's URL is refused")
    func foreignURLIsRefused() throws {
        let url = try #require(URL(string: "cleanshot://capture-area"))
        #expect(throws: AutomationError.notAKadrURL("cleanshot://capture-area")) {
            try AutomationParser.command(from: url)
        }
    }

    // MARK: - Wire format

    @Test("Commands survive the trip to the agent as JSON", arguments: AutomationVerb.allCases)
    func commandsRoundTripAsJSON(verb: AutomationVerb) throws {
        let values: [AutomationParameter: String] = verb.parameters.contains(.path)
            ? [.path: "/tmp/a.png"]
            : [:]
        let command = try AutomationParser.command(verb: verb, values: values)
        let envelope = AutomationEnvelope(command: command, replyPortName: "reply")
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(AutomationEnvelope.self, from: data)
        #expect(decoded == envelope)
    }

    @Test("Only the verbs that make a file are worth waiting for")
    func producesOutputIsHonest() throws {
        #expect(try AutomationParser.command(verb: .captureArea, values: [:]).producesOutput)
        #expect(try AutomationParser.command(verb: .captureText, values: [:]).producesOutput)
        #expect(try AutomationParser.command(verb: .stopRecording, values: [:]).producesOutput)
        // Starting a recording has nothing to hand back yet.
        #expect(try !AutomationParser.command(verb: .recordScreen, values: [:]).producesOutput)
        #expect(try !AutomationParser.command(verb: .openSettings, values: [:]).producesOutput)
        #expect(try !AutomationParser.command(verb: .closeAllPins, values: [:]).producesOutput)
    }
}
