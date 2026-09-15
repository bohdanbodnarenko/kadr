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

    @Test("A reply port name is unique per invocation")
    func replyPortNamesAreUnique() {
        #expect(AutomationPort.reply() != AutomationPort.reply())
        #expect(AutomationPort.reply().hasPrefix(AutomationPort.agent))
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
        let listener = AutomationListener(portName: portName) { command, reply in
            #expect(command == .captureArea(CaptureOptions(action: .copy)))
            reply(.file("/tmp/round-trip.png"))
        }
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
        let listener = AutomationListener(portName: portName) { _, reply in
            // Stands in for the user taking their time over a selection.
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                reply(.cancelled)
            }
        }
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
