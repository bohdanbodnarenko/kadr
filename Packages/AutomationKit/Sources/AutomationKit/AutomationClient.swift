import Darwin
import Foundation

/// Sends a command to the running agent and waits for the answer (docs/06 M19).
///
/// The CLI does not capture anything itself: every ScreenCaptureKit call has to stay in
/// the agent so the Screen Recording grant attaches to the app the user actually approved
/// (docs/04 §1, §4.1). So `kadr capture-area` is a messenger — it hands the agent a
/// command and prints what comes back.
///
/// Blocking by design: a command-line tool's job is to finish and set an exit code.
public enum AutomationClient {
    /// Sends `command` and waits up to `timeout` for a response.
    ///
    /// - Parameters:
    ///   - waitsForResult: when false the command is delivered and the call returns `.ok`
    ///     immediately, which is what `--no-wait` is for.
    ///   - portName: the agent's port. Only tests pass anything else.
    public static func send(
        _ command: AppCommand,
        waitsForResult: Bool = true,
        portName: String = AutomationPort.agent,
        timeout: TimeInterval = AutomationParser.Invocation.defaultTimeout
    ) throws -> AutomationResponse {
        guard let remote = MachChannel.lookUp(portName) else {
            throw AutomationError.agentNotRunning
        }
        defer { MachChannel.release(remote) }
        let payload = try JSONEncoder().encode(AutomationEnvelope(command: command))

        guard waitsForResult else {
            try check(MachChannel.send(
                payload,
                id: AutomationPort.MessageID.request,
                to: remote,
                timeout: deliveryTimeout
            ))
            return .ok
        }

        // A private receive right for the answer. The agent gets a send-once right to it
        // inside the request, so the reply cannot be addressed anywhere else, and no
        // named port is left behind if this process exits early.
        guard let replyPort = MachChannel.makeReceivePort() else {
            throw AutomationError.agentNotRunning
        }
        defer { MachChannel.destroy(replyPort) }

        try check(MachChannel.send(
            payload,
            id: AutomationPort.MessageID.request,
            to: remote,
            replyPort: replyPort,
            timeout: deliveryTimeout
        ))

        switch MachChannel.receive(on: replyPort, timeout: timeout) {
        case let .success(received):
            // The agent dropped the request without answering: the kernel says so with a
            // send-once notification rather than a reply.
            guard received.id == AutomationPort.MessageID.response else {
                return .failed("Kadr did not answer.")
            }
            return (try? JSONDecoder().decode(AutomationResponse.self, from: received.payload))
                ?? .failed("Kadr sent a reply that could not be read.")
        case .failure(.timedOut):
            throw AutomationError.timedOut
        case .failure(.malformed):
            return .failed("Kadr did not answer.")
        case .failure(.kernel):
            throw AutomationError.agentNotRunning
        }
    }

    /// How long the agent gets to accept the message itself. Not the capture's budget —
    /// that is `timeout` — just the handoff.
    private static let deliveryTimeout: TimeInterval = 5

    private static func check(_ status: kern_return_t) throws {
        switch status {
        case KERN_SUCCESS:
            return
        case MACH_SEND_TIMED_OUT:
            throw AutomationError.timedOut
        default:
            throw AutomationError.agentNotRunning
        }
    }
}
