import CoreFoundation
import Foundation

/// The agent's end of the automation channel (docs/03 §8.4).
///
/// Opens a named Mach port on the main run loop and hands every command that arrives to
/// the app's router. The port costs nothing when nobody is talking to it: no thread, no
/// timer, one run-loop source — which is what the idle budget requires (PRD §8).
///
/// A command may take as long as the user takes to drag a selection, so the handler
/// answers through a completion rather than by returning; the reply is then posted back to
/// the caller's own port.
@MainActor
public final class AutomationListener {
    public typealias Completion = @MainActor (AutomationResponse) -> Void
    public typealias Handler = @MainActor (AppCommand, @escaping Completion) -> Void

    private let handler: Handler
    private let portName: String
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    public init(portName: String = AutomationPort.agent, handler: @escaping Handler) {
        self.portName = portName
        self.handler = handler
    }

    // No `deinit` cleanup: a Mach port is not `Sendable`, so a nonisolated deinit cannot
    // touch it. The listener is owned by the app delegate for the process's lifetime and
    // torn down through `stop()`; the kernel reclaims the port when the process exits.

    public var isListening: Bool {
        port != nil
    }

    /// Starts listening. Returns false when the name is already taken — which means
    /// another Kadr is running, and this one should not pretend to own automation.
    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let local = CFMessagePortCreateLocal(
            nil,
            portName as CFString,
            { _, _, data, info in
                guard let info, let data else { return nil }
                let listener = Unmanaged<AutomationListener>.fromOpaque(info).takeUnretainedValue()
                // The run-loop source lives on the main run loop, so this callback is
                // already on the main thread; the assumption is asserted, not assumed.
                MainActor.assumeIsolated {
                    listener.receive(data as Data)
                }
                return nil
            },
            &context,
            nil
        ) else {
            return false
        }

        guard let runLoopSource = CFMessagePortCreateRunLoopSource(nil, local, 0) else {
            CFMessagePortInvalidate(local)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        port = local
        source = runLoopSource
        return true
    }

    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let port {
            CFMessagePortInvalidate(port)
            self.port = nil
        }
    }

    // MARK: - Private

    private func receive(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(AutomationEnvelope.self, from: data) else {
            return
        }
        let replyPortName = envelope.replyPortName
        handler(envelope.command) { response in
            guard let replyPortName else { return }
            Self.reply(response, to: replyPortName)
        }
    }

    /// Posts the answer to the caller's one-shot port. A caller that gave up and exited
    /// leaves no port behind, and that is not an error worth reporting.
    private static func reply(_ response: AutomationResponse, to portName: String) {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString),
              let data = try? JSONEncoder().encode(response)
        else {
            return
        }
        defer { CFMessagePortInvalidate(remote) }
        _ = CFMessagePortSendRequest(
            remote,
            AutomationPort.MessageID.response,
            data as CFData,
            replyTimeout,
            0,
            nil,
            nil
        )
    }

    private static let replyTimeout: CFTimeInterval = 5
}
