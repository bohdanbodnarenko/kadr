import Foundation
import Testing
@testable import Shared

/// A helper that accepts every request and never answers.
private final class SilentService: NSObject, VisionServiceProtocol, @unchecked Sendable {
    func analyze(imageData: Data, optionsData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func compressImage(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func encodeGIF(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func stitchScroll(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func indexHistory(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func subjectMask(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func transcribe(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func speechStatus(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func installSpeechModel(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func cancelSpeech() {}
    func warmUpSpeech(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func startLiveSpeech(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {}
    func feedLiveSpeechAudio(_ pcmData: Data) {}
    func stopLiveSpeech() {}
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = SilentService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: VisionServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// docs/18 STU-8: the bound fires for a helper that is alive and silent.
@Suite("Helper timeout")
struct VisionClientTimeoutTests {
    @Test("A helper that never replies times out, naming the operation")
    func silentHelperTimesOut() async throws {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VisionServiceProtocol.self)
        connection.resume()

        let started = ContinuousClock.now
        await #expect(throws: VisionClient.ClientError.timedOut(.transcription)) {
            _ = try await VisionClient.race(
                on: UncheckedSendableBox(connection),
                operation: .transcription,
                timeout: .milliseconds(200),
                fallback: .transcriptionFailed
            ) { service, reply in
                service.transcribe(requestData: Data(), reply: reply)
            }
        }
        #expect(ContinuousClock.now - started < .seconds(10), "the timeout waited on the silent helper")
    }

    @Test("Timeout messages name what stalled", arguments: [
        (VisionClient.Operation.transcription, "Transcription did not finish in time."),
        (.textRecognition, "Text recognition did not finish in time."),
        (.speechModelInstall, "Installing the language model did not finish in time.")
    ])
    func messages(operation: VisionClient.Operation, expected: String) {
        #expect(VisionClient.ClientError.timedOut(operation).errorDescription == expected)
    }
}
