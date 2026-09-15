import Foundation

/// How a command ended. Maps onto the CLI's exit code (docs/06 M19: non-zero on cancel).
public enum AutomationStatus: String, Codable, Sendable, Hashable {
    case ok
    /// The user pressed Escape, or closed the picker without choosing.
    case cancelled
    case failed
    /// The verb parsed but this build cannot do it — a permission is missing, say.
    case unsupported
    /// Capture Text found nothing to copy (docs/16 X-4).
    case noText
}

/// What the agent sends back to a CLI invocation or a Shortcuts action.
public struct AutomationResponse: Codable, Hashable, Sendable {
    public var status: AutomationStatus
    /// Files the command produced, in the order they were made.
    public var paths: [String]
    /// Recognised text, for `capture-text`.
    public var text: String?
    /// A human-readable explanation, always present for `.failed`.
    public var message: String?

    public init(
        status: AutomationStatus,
        paths: [String] = [],
        text: String? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.paths = paths
        self.text = text
        self.message = message
    }

    public static let ok = AutomationResponse(status: .ok)
    public static let cancelled = AutomationResponse(status: .cancelled, message: "Cancelled.")

    public static func file(_ path: String) -> AutomationResponse {
        AutomationResponse(status: .ok, paths: [path])
    }

    public static func failed(_ message: String) -> AutomationResponse {
        AutomationResponse(status: .failed, message: message)
    }

    /// The process exit code a CLI should use.
    ///
    /// Cancel is deliberately not 1: a script wants to tell "the user pressed Escape"
    /// apart from "something broke", and only distinct codes let it (docs/06 M19).
    public var exitCode: Int32 {
        switch status {
        case .ok: 0
        case .failed: 1
        case .cancelled: 2
        case .unsupported: 3
        case .noText: 4
        }
    }

    /// Exit code for a command line that did not parse. Matches `sysexits.h` EX_USAGE,
    /// which is what shell users expect from a usage error.
    public static let usageExitCode: Int32 = 64

    /// One JSON object per invocation, newline-terminated, for `--json`.
    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else {
            return #"{"status":"failed","message":"Could not encode the result.","paths":[]}"#
        }
        return json
    }

    /// What a plain (non-`--json`) invocation prints: the paths, or the text, or nothing.
    public var plainOutput: String? {
        if let text, !text.isEmpty {
            return text
        }
        guard !paths.isEmpty else { return nil }
        return paths.joined(separator: "\n")
    }
}

/// A command on its way to the agent, and where to send the answer.
///
/// The reply port is named rather than connected: the CLI creates its own local port,
/// tells the agent its name, and waits. That is what lets a capture take as long as the
/// user needs to drag a selection without the request itself timing out.
public struct AutomationEnvelope: Codable, Hashable, Sendable {
    public var command: AppCommand
    public var replyPortName: String?

    public init(command: AppCommand, replyPortName: String? = nil) {
        self.command = command
        self.replyPortName = replyPortName
    }
}

/// The Mach port names the agent and the CLI meet on.
///
/// A CFMessagePort, not a socket: this is local IPC between two processes owned by the
/// same user, and Kadr links no networking (CLAUDE.md rule 1). It also needs no launchd
/// registration, which an `NSXPCListener(machServiceName:)` would.
public enum AutomationPort {
    public static let agent = "app.kadr.Kadr.automation"

    /// A one-shot reply port, unique per invocation.
    public static func reply(id: UUID = UUID()) -> String {
        "\(agent).reply.\(id.uuidString)"
    }

    /// Message IDs on the wire. One for the request, one for the answer.
    public enum MessageID {
        public static let request: Int32 = 1
        public static let response: Int32 = 2
    }
}
