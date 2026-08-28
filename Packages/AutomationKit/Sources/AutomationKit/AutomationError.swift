import Foundation

/// Why a URL or a command line could not become an `AppCommand`.
///
/// Every case names the thing that was wrong and, where it helps, what would have been
/// right: automation failures are read in a terminal or a Raycast log, with no way to ask
/// a follow-up question.
public enum AutomationError: Error, Hashable, Sendable {
    case missingVerb
    case unknownVerb(String)
    case unknownParameter(verb: String, name: String)
    case missingValue(name: String)
    case invalidValue(name: String, value: String)
    case missingRequiredParameter(verb: String, name: String)
    /// x, y, width and height are all-or-nothing: half a rectangle is never a sane guess.
    case incompleteRegion
    case notAKadrURL(String)
    case agentNotRunning
    case timedOut
}

extension AutomationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingVerb:
            "No command given. Try `kadr help`."
        case let .unknownVerb(verb):
            "Unknown command “\(verb)”. Try `kadr help` for the list."
        case let .unknownParameter(verb, name):
            "“\(verb)” does not take a “\(name)” parameter."
        case let .missingValue(name):
            "“\(name)” needs a value."
        case let .invalidValue(name, value):
            "“\(value)” is not a valid value for “\(name)”."
        case let .missingRequiredParameter(verb, name):
            "“\(verb)” needs a “\(name)” parameter."
        case .incompleteRegion:
            "A region needs all four of x, y, width and height."
        case let .notAKadrURL(url):
            "“\(url)” is not a kadr:// URL."
        case .agentNotRunning:
            "Kadr is not running."
        case .timedOut:
            "Kadr did not answer in time."
        }
    }
}
