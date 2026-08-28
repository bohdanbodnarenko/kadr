import AutomationKit
import Foundation

// The `kadr` command-line tool (docs/03 §8.4, docs/06 M19).
//
// It captures nothing. Every ScreenCaptureKit call has to happen in the agent, because
// that is the process the user granted Screen Recording to (docs/04 §1, §4.1) — so this
// tool parses the verb, hands it to the running agent over a local Mach port, waits, and
// prints whatever comes back. Exit codes are the contract a script actually depends on:
// 0 done, 1 failed, 2 the user cancelled, 64 the command line was wrong.
//
// Installed by Settings → Advanced, which symlinks it into a directory on $PATH.

/// Writes to stderr so `kadr capture-area > shot.txt` never picks up an error message.
func complain(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func usage() -> String {
    var lines = [
        "kadr — automation for the Kadr screen capture app.",
        "",
        "Usage: kadr <command> [--option value] [--json] [--no-wait] [--timeout seconds]",
        "",
        "Commands:"
    ]
    let width = AutomationVerb.allCases.map(\.rawValue.count).max() ?? 0
    for verb in AutomationVerb.allCases {
        let name = verb.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
        lines.append("  \(name)  \(verb.summary)")
    }
    lines.append(contentsOf: [
        "",
        "Options are documented per command in docs/AUTOMATION.md.",
        "CleanShot verb names are accepted as aliases, so existing scripts keep working.",
        "",
        "Exit codes: 0 done · 1 failed · 2 cancelled · 3 unsupported · 64 usage."
    ])
    return lines.joined(separator: "\n")
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments.first == "help" || arguments.first == "--help" || arguments.first == "-h" {
    print(usage())
    exit(arguments.isEmpty ? AutomationResponse.usageExitCode : 0)
}

let invocation: AutomationParser.Invocation
do {
    invocation = try AutomationParser.invocation(arguments: arguments)
} catch {
    complain((error as? AutomationError)?.localizedDescription ?? error.localizedDescription)
    exit(AutomationResponse.usageExitCode)
}

do {
    let response = try AutomationClient.send(
        invocation.command,
        waitsForResult: invocation.waitsForResult,
        timeout: invocation.timeout
    )
    if invocation.wantsJSON {
        print(response.jsonLine())
    } else {
        if let output = response.plainOutput {
            print(output)
        }
        if response.status != .ok, let message = response.message {
            complain(message)
        }
    }
    exit(response.exitCode)
} catch {
    let message = (error as? AutomationError)?.localizedDescription ?? error.localizedDescription
    if invocation.wantsJSON {
        print(AutomationResponse.failed(message).jsonLine())
    } else {
        complain(message)
    }
    exit(1)
}
