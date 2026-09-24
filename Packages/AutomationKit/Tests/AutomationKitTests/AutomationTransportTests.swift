import Foundation
import Testing
@testable import AutomationKit

/// The response contract the CLI and Shortcuts both read (docs/06 M19).
@Suite("Automation responses")
struct AutomationResponseTests {
    @Test("Cancel exits non-zero, and differently from a failure")
    func exitCodes() {
        #expect(AutomationResponse.ok.exitCode == 0)
        #expect(AutomationResponse.cancelled.exitCode == 2)
        #expect(AutomationResponse.failed("nope").exitCode == 1)
        #expect(AutomationResponse(status: .unsupported).exitCode == 3)
        #expect(AutomationResponse(status: .noText).exitCode == 4)
        #expect(AutomationResponse.denied.exitCode == 77)
    }

    @Test("--json prints one object with the file path in it")
    func jsonLineCarriesThePath() throws {
        let json = AutomationResponse.file("/tmp/shot.png").jsonLine()
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self,
            from: #require(json.data(using: .utf8))
        )
        #expect(decoded.status == .ok)
        #expect(decoded.paths == ["/tmp/shot.png"])
        #expect(json.contains("\"paths\":[\"\\/tmp\\/shot.png\"]") || json.contains("\"paths\":[\"/tmp/shot.png\"]"))
    }

    @Test("Plain output is the path, or the text, or nothing")
    func plainOutput() {
        #expect(AutomationResponse.file("/tmp/a.png").plainOutput == "/tmp/a.png")
        #expect(AutomationResponse(status: .ok, paths: ["/a", "/b"]).plainOutput == "/a\n/b")
        #expect(AutomationResponse(status: .ok, text: "hello").plainOutput == "hello")
        #expect(AutomationResponse.ok.plainOutput == nil)
    }
}

/// The Mach-port channel between the CLI and the agent.
///
/// Both ends run in this process: the listener is created on the main run loop, and the
/// client blocks on a background thread the way the real CLI blocks on its own process.
@Suite("Automation transport")
struct AutomationTransportTests {
    @Test("A command reaches the agent and the answer comes back")
    @MainActor
    func roundTrip() async throws {
        let portName = "\(AutomationPort.agent).test.\(UUID().uuidString)"
        let listener = AutomationListener(portName: portName, authorize: { _ in true }, handler: { command, reply in
            #expect(command == .captureArea(CaptureOptions(action: .copy)))
            reply(.file("/tmp/round-trip.png"))
        })
        #expect(listener.start())
        defer { listener.stop() }

        let response = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try AutomationClient.send(
                        .captureArea(CaptureOptions(action: .copy)),
                        portName: portName,
                        timeout: 5
                    )
                })
            }
        }
        #expect(response.status == .ok)
        #expect(response.paths == ["/tmp/round-trip.png"])
    }

    @Test("An answer that takes a while still arrives")
    @MainActor
    func slowReplyStillArrives() async throws {
        let portName = "\(AutomationPort.agent).test.\(UUID().uuidString)"
        let listener = AutomationListener(portName: portName, authorize: { _ in true }, handler: { _, reply in
            // Stands in for the user taking their time over a selection.
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                reply(.cancelled)
            }
        })
        #expect(listener.start())
        defer { listener.stop() }

        let response = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try AutomationClient.send(.captureArea(.none), portName: portName, timeout: 5)
                })
            }
        }
        #expect(response.status == .cancelled)
        #expect(response.exitCode == 2)
    }

    @Test("A sender the listener does not trust is refused and nothing runs")
    @MainActor
    func untrustedSenderIsDenied() async throws {
        let portName = "\(AutomationPort.agent).test.\(UUID().uuidString)"
        var ran = false
        var seenPID: pid_t?
        let listener = AutomationListener(
            portName: portName,
            authorize: { peer in
                seenPID = peer.pid
                return false
            },
            handler: { _, reply in
                ran = true
                reply(.ok)
            }
        )
        #expect(listener.start())
        defer { listener.stop() }

        let response = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try AutomationClient.send(.openHistory, portName: portName, timeout: 5)
                })
            }
        }
        #expect(response.status == .denied)
        #expect(response.exitCode == 77)
        #expect(!ran)
        // The kernel's audit token names this very process as the sender.
        #expect(seenPID == getpid())
    }

    @Test("The default trust check accepts this process and a bundle's own files")
    @MainActor
    func trustRules() {
        let bundle = URL(fileURLWithPath: "/Applications/Kadr.app")
        #expect(AutomationTrust.isInsideBundle(
            URL(fileURLWithPath: "/Applications/Kadr.app/Contents/Helpers/kadr"),
            bundle: bundle
        ))
        #expect(!AutomationTrust.isInsideBundle(
            URL(fileURLWithPath: "/Applications/Kadr.app.evil/kadr"),
            bundle: bundle
        ))
        #expect(!AutomationTrust.isInsideBundle(URL(fileURLWithPath: "/usr/local/bin/kadr"), bundle: bundle))
    }

    @Test("A listener that never answers still lets the client finish")
    @MainActor
    func droppedRequest() async throws {
        let portName = "\(AutomationPort.agent).test.\(UUID().uuidString)"
        var held: AutomationListener.Completion?
        let listener = AutomationListener(portName: portName, authorize: { _ in true }, handler: { _, reply in
            held = reply
        })
        #expect(listener.start())

        let response = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try AutomationClient.send(.openHistory, portName: portName, timeout: 5)
                })
            }
            // Tearing the listener down drops the unanswered request's reply right.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                listener.stop()
                held = nil
            }
        }
        #expect(response.status == .failed)
        _ = held
    }

    @Test("Talking to an agent that is not running fails cleanly")
    func noAgent() {
        #expect(throws: AutomationError.agentNotRunning) {
            try AutomationClient.send(
                .openHistory,
                portName: "\(AutomationPort.agent).absent.\(UUID().uuidString)",
                timeout: 1
            )
        }
    }
}
