import CoreFoundation
import Darwin
import Foundation
import os
import Shared

/// The agent's end of the automation channel (docs/03 §8.4).
///
/// Registers a named Mach port on the main run loop and hands every command that arrives
/// to the app's router. The port costs nothing when nobody is talking to it: no thread, no
/// timer, one run-loop source — which is what the idle budget requires (PRD §8).
///
/// Every message is checked against `authorize` before anything runs (docs/17 T-OUT-12).
/// The sender is identified by the audit token the kernel attached to the message, not by
/// anything the sender says about itself, and by default must be code signed by Kadr's own
/// team. A refused sender gets `.denied` back and nothing happens.
///
/// A command may take as long as the user takes to drag a selection, so the handler
/// answers through a completion rather than by returning; the reply goes back on the
/// send-once right the request carried.
@MainActor
public final class AutomationListener {
    public typealias Completion = @MainActor (AutomationResponse) -> Void
    public typealias Handler = @MainActor (AppCommand, @escaping Completion) -> Void
    public typealias Authorizer = @MainActor (AutomationPeer) -> Bool

    private let handler: Handler
    private let authorize: Authorizer
    private let portName: String
    private var machPort: mach_port_t = 0
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let logger = KadrLog.logger(.app)

    public init(
        portName: String = AutomationPort.agent,
        authorize: @escaping Authorizer = AutomationTrust.isTrusted,
        handler: @escaping Handler
    ) {
        self.portName = portName
        self.authorize = authorize
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
        guard let registered = MachChannel.registerService(named: portName) else { return false }

        var context = CFMachPortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFree: DarwinBoolean = false
        guard let local = CFMachPortCreateWithPort(
            nil,
            registered,
            { _, message, _, info in
                guard let info, let message else { return }
                let listener = Unmanaged<AutomationListener>.fromOpaque(info).takeUnretainedValue()
                // The run-loop source lives on the main run loop, so this callback is
                // already on the main thread; the assumption is asserted, not assumed.
                MainActor.assumeIsolated {
                    listener.receive(message)
                }
            },
            &context,
            &shouldFree
        ), let runLoopSource = CFMachPortCreateRunLoopSource(nil, local, 0) else {
            MachChannel.destroy(registered)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        machPort = registered
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
            CFMachPortInvalidate(port)
            self.port = nil
        }
        if machPort != 0 {
            // Dropping the receive right is what frees the registered name.
            MachChannel.destroy(machPort)
            machPort = 0
        }
    }

    // MARK: - Private

    private func receive(_ message: UnsafeMutableRawPointer) {
        guard let received = MachChannel.parse(message) else { return }
        let replyPort = received.replyPort
        guard received.id == AutomationPort.MessageID.request,
              let envelope = try? JSONDecoder().decode(AutomationEnvelope.self, from: received.payload)
        else {
            MachChannel.release(replyPort)
            return
        }

        let peer = AutomationPeer(auditToken: received.auditToken)
        guard authorize(peer) else {
            logger.error("Refused an automation command from pid \(peer.pid, privacy: .public)")
            Self.reply(.denied, to: replyPort)
            return
        }

        let pending = PendingReply(replyPort)
        handler(envelope.command) { response in
            pending.answer(response)
        }
    }

    /// The reply right for one request.
    ///
    /// Answered once — a send-once right is spent by the first reply. A request the agent
    /// drops without answering releases the right when the last completion goes away, and
    /// the kernel tells the waiting CLI so, rather than leaving it to time out.
    private final class PendingReply: @unchecked Sendable {
        private var port: mach_port_t

        init(_ port: mach_port_t) {
            self.port = port
        }

        @MainActor
        func answer(_ response: AutomationResponse) {
            guard port != 0 else { return }
            AutomationListener.reply(response, to: port)
            port = 0
        }

        deinit {
            MachChannel.release(port)
        }
    }

    /// Posts the answer on the request's send-once right. A caller that gave up and
    /// exited leaves a dead right behind, and that is not an error worth reporting.
    private static func reply(_ response: AutomationResponse, to replyPort: mach_port_t) {
        guard replyPort != 0 else { return }
        guard let data = try? JSONEncoder().encode(response) else {
            MachChannel.release(replyPort)
            return
        }
        let status = MachChannel.reply(
            data,
            id: AutomationPort.MessageID.response,
            to: replyPort,
            timeout: replyTimeout
        )
        if status != KERN_SUCCESS {
            MachChannel.release(replyPort)
        }
    }

    private static let replyTimeout: TimeInterval = 5
}
