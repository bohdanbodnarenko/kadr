import Foundation

/// `kadr help <command>`: what one command does and the options it takes (docs/18 OUT-14).
///
/// The general usage pointed at `docs/AUTOMATION.md`, a file in the source repository that
/// an installed copy of Kadr does not have. The options are already declared per verb for
/// the parser, so the help is built from the same table and cannot drift from it.
public enum AutomationHelp {
    /// The help for `verb`, ready to print.
    public static func text(for verb: AutomationVerb) -> String {
        var lines = ["kadr \(verb.rawValue) — \(verb.summary)"]
        let parameters = verb.parameters
        if parameters.isEmpty {
            lines.append(contentsOf: ["", "This command takes no options."])
        } else {
            lines.append(contentsOf: ["", "Options:"])
            let width = parameters.map(\.rawValue.count).max() ?? 0
            for parameter in parameters {
                let name = parameter.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
                var line = "  --\(name)  \(parameter.summary)"
                if !parameter.aliases.isEmpty {
                    line += " (also: " + parameter.aliases.map { "--\($0)" }.joined(separator: ", ") + ")"
                }
                lines.append(line)
            }
        }
        let aliases = AutomationVerb.aliases.filter { $0.value == verb }.keys.sorted()
        if !aliases.isEmpty {
            lines.append(contentsOf: ["", "Also accepted as: " + aliases.joined(separator: ", ")])
        }
        return lines.joined(separator: "\n")
    }
}

public extension AutomationParameter {
    /// One line on what the option does.
    var summary: String {
        switch self {
        case .action: "What to do with the result: " + CaptureAction.allCases.map(\.rawValue).joined(separator: ", ")
        case .x: "Region left edge, in AppKit screen points (origin bottom-left)."
        case .y: "Region bottom edge, in AppKit screen points."
        case .width: "Width of the region, in points."
        case .height: "Height of the region, in points."
        case .delay: "Self-timer in seconds; 0 turns it off."
        case .cursor: "Include the pointer (true or false)."
        case .fps: "Frames per second, 1 to 120."
        case .microphone: "Record the microphone (true or false)."
        case .systemAudio: "Record system audio (true or false)."
        case .path: "The file to act on."
        case .state: "hide, show or toggle."
        case .tab: "The Settings tab to open."
        case .linebreaks: "Keep line breaks in recognised text (true or false)."
        case .display: "1-based display index; 1 is the screen with the menu bar."
        case .start: "With a region, begin at once (true, default) or show the overlay first (false)."
        case .autoScroll: "Let Kadr scroll the page (true or false)."
        }
    }
}
