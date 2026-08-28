import CoreFoundation
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
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw AutomationError.agentNotRunning
        }
        defer { CFMessagePortInvalidate(remote) }

        guard waitsForResult else {
            try deliver(AutomationEnvelope(command: command), to: remote)
            return .ok
        }

        let inbox = ResponseInbox()
        let portName = AutomationPort.reply()
        guard let replyPort = inbox.makePort(named: portName) else {
            throw AutomationError.agentNotRunning
        }
        defer { CFMessagePortInvalidate(replyPort) }

        guard let source = CFMessagePortCreateRunLoopSource(nil, replyPort, 0) else {
            throw AutomationError.agentNotRunning
        }
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        defer { CFRunLoopRemoveSource(runLoop, source, .defaultMode) }

        try deliver(AutomationEnvelope(command: command, replyPortName: portName), to: remote)

        let deadline = Date().addingTimeInterval(timeout)
        while inbox.response == nil {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AutomationError.timedOut }
            // Returns as soon as the reply arrives, so this is a wait and not a poll.
            CFRunLoopRunInMode(.defaultMode, remaining, true)
        }
        guard let response = inbox.response else { throw AutomationError.timedOut }
        return response
    }

    /// How long the agent gets to accept the message itself. Not the capture's budget —
    /// that is `timeout` — just the handoff.
    private static let deliveryTimeout: CFTimeInterval = 5

    private static func deliver(_ envelope: AutomationEnvelope, to remote: CFMessagePort) throws {
        let data = try JSONEncoder().encode(envelope)
        let status = CFMessagePortSendRequest(
            remote,
            AutomationPort.MessageID.request,
            data as CFData,
            deliveryTimeout,
            0,
            nil,
            nil
        )
        guard status == kCFMessagePortSuccess else {
            throw status == kCFMessagePortSendTimeout
                ? AutomationError.timedOut
                : AutomationError.agentNotRunning
        }
    }
}

/// Holds the reply until the run loop hands control back.
///
/// A class, not a captured local, because the CFMessagePort callback is a C function
/// pointer: the only thing it can carry is one opaque pointer, and this is what that
/// pointer points at. Confined to the thread running the loop, which is the thread that
/// created it — `@unchecked Sendable` records that invariant rather than hiding it.
private final class ResponseInbox: @unchecked Sendable {
    var response: AutomationResponse?

    func makePort(named name: String) -> CFMessagePort? {
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        return CFMessagePortCreateLocal(
            nil,
            name as CFString,
            { _, _, data, info in
                guard let info, let data else { return nil }
                let inbox = Unmanaged<ResponseInbox>.fromOpaque(info).takeUnretainedValue()
                inbox.response = (try? JSONDecoder().decode(AutomationResponse.self, from: data as Data))
                    ?? .failed("Kadr sent a reply that could not be read.")
                CFRunLoopStop(CFRunLoopGetCurrent())
                return nil
            },
            &context,
            nil
        )
    }
}
