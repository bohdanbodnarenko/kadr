import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Talks to the Vision helper (docs/04 §1).
///
/// Lives in Shared so both the agent and the editor can call it. The helper is still the
/// only process that *loads* Vision — this type is just the XPC client. The connection is
/// made on demand and let go afterwards so an idle helper can exit.
@MainActor
public final class VisionClient {
    private let signposter = KadrLog.signposter(.capture)
    private var connection: NSXPCConnection?

    public enum ClientError: LocalizedError {
        case helperUnavailable
        case encodingFailed
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .helperUnavailable: "Kadr's text recognition helper is not available."
            case .encodingFailed: "Kadr could not prepare the image for text recognition."
            case .timedOut: "Text recognition did not finish in time."
            }
        }
    }

    public init() {}

    /// How long to wait before giving up on the helper.
    ///
    /// XPC does not promise a reply. A helper that dies at the wrong moment, or a launch
    /// that never happens, leaves the caller waiting forever — and this call sits between
    /// a user pressing a hotkey and anything appearing on screen, so "forever" is the one
    /// outcome that must be impossible.
    public static let timeout = Duration.seconds(15)

    /// Recognises text and codes in an image.
    ///
    /// Signposted end to end, because doc 03 §1.7 budgets a typical region at under a
    /// second and that has to include the helper spawning and loading its models.
    public func analyze(_ image: CGImage, options: TextRecognitionOptions) async throws -> VisionAnalysis {
        let state = signposter.beginInterval("ocr")
        defer { signposter.endInterval("ocr", state) }

        guard let pngData = Self.pngData(from: image) else { throw ClientError.encodingFailed }
        let optionsData = try JSONEncoder().encode(options)
        return try await send(timeout: Self.timeout, fallback: .recognitionFailed) { service, reply in
            service.analyze(imageData: pngData, optionsData: optionsData, reply: reply)
        }
    }

    /// Turns a recording into a GIF, in the helper (docs/03 §1.8).
    ///
    /// Paths cross the wire rather than data: a recording can be hundreds of megabytes,
    /// and the point of doing this in the helper is that the agent never holds the frames.
    public func encodeGIF(_ request: GIFRequest) async throws -> GIFResponse {
        let state = signposter.beginInterval("gif")
        defer { signposter.endInterval("gif", state) }

        let requestData = try JSONEncoder().encode(request)
        // Encoding a long recording legitimately takes a while, so this bound is far more
        // generous than the recognition one — it exists to catch a dead helper, not a slow
        // encode.
        return try await send(timeout: .seconds(600), fallback: .recognitionFailed) { service, reply in
            service.encodeGIF(requestData: requestData, reply: reply)
        }
    }

    /// Re-encodes a capture smaller, in the helper (docs/09 U2.4).
    ///
    /// Paths cross the wire rather than pixels: a compression decodes the capture and
    /// encodes it several times over while it searches for a size, and the point of doing
    /// that in the helper is that the agent never holds any of it.
    public func compressImage(_ request: CompressRequest) async throws -> CompressResponse {
        let state = signposter.beginInterval("compress")
        defer { signposter.endInterval("compress", state) }

        let requestData = try JSONEncoder().encode(request)
        // A handful of encodes of one still; generous for a slow machine, bounded so a
        // wedged helper cannot leave the card spinning.
        return try await send(timeout: .seconds(60), fallback: .compressionFailed) { service, reply in
            service.compressImage(requestData: requestData, reply: reply)
        }
    }

    /// Stitches a scrolling capture, in the helper (docs/03 §1.6).
    ///
    /// Paths again, for the same reason as the GIF encoder and then some: a long scroll is
    /// a hundred full-screen frames, and the finished strip can be a hundred megabytes.
    /// None of that should pass through — or be held by — the menu bar agent.
    public func stitchScroll(_ request: ScrollStitchRequest) async throws -> ScrollStitchResponse {
        let state = signposter.beginInterval("scroll stitch")
        defer { signposter.endInterval("scroll stitch", state) }

        let requestData = try JSONEncoder().encode(request)
        return try await send(timeout: .seconds(300), fallback: .stitchFailed) { service, reply in
            service.stitchScroll(requestData: requestData, reply: reply)
        }
    }

    /// Asks the helper to read a batch of captures for the history index (docs/03 §5).
    ///
    /// Cheap to call and safe to stop calling: one batch per call, and the caller decides
    /// whether to ask again — which is where the "on mains power, opted in, never on a
    /// timer" rule lives. The helper only recognises; the caller writes what comes back
    /// into the library it owns (docs/04 §9).
    public func indexHistory(_ request: HistoryIndexRequest) async throws -> HistoryIndexResponse {
        let state = signposter.beginInterval("historyIndex")
        defer { signposter.endInterval("historyIndex", state) }

        let requestData = try JSONEncoder().encode(request)
        // A batch is a handful of OCR passes; generous enough for a slow machine, bounded
        // so a wedged helper cannot leave the pass hanging forever.
        return try await send(timeout: .seconds(120), fallback: .historyUnavailable) { service, reply in
            service.indexHistory(requestData: requestData, reply: reply)
        }
    }

    /// Asks the helper to separate the subject from the background (docs/06 M23).
    ///
    /// Paths again: the capture and the mask are both full-size images, and the point of
    /// doing this in the helper is that the editor never holds the segmentation model.
    public func subjectMask(_ request: SubjectMaskRequest) async throws -> SubjectMaskResponse {
        let state = signposter.beginInterval("subjectMask")
        defer { signposter.endInterval("subjectMask", state) }

        let requestData = try JSONEncoder().encode(request)
        // Segmenting a 5K capture on an older machine is seconds, not minutes; this bound
        // exists to catch a dead helper, not a slow model.
        return try await send(timeout: .seconds(60), fallback: .maskFailed) { service, reply in
            service.subjectMask(requestData: requestData, reply: reply)
        }
    }

    // MARK: - The one round trip

    /// What every call to the helper does: connect, send, decode, and never hang.
    ///
    /// Each of the five requests used to carry its own copy of this — a task group racing a
    /// sleep, a `ResumeOnce`, a proxy error handler and the same three-way reply check, all
    /// spelled out five times (docs/07 LOW). They differ in exactly three things: how long
    /// to wait, which method to call, and what an empty reply means.
    ///
    /// - Parameters:
    ///   - timeout: XPC does not promise a reply, so every call needs a bound.
    ///   - fallback: the error to report when the helper replies with neither data nor an
    ///     error, which should not happen and must still be an error rather than a hang.
    ///   - invoke: calls the method this request wants.
    private func send<Response: Decodable>(
        timeout: Duration,
        fallback: VisionServiceError,
        invoke: @escaping @Sendable (any VisionServiceProtocol, @escaping @Sendable (Data?, (any Error)?) -> Void)
            -> Void
    ) async throws -> Response {
        let connection = connection ?? makeConnection()
        self.connection = connection

        // `NSXPCConnection` is not `Sendable`; it is used only from the request task,
        // which is the single consumer, so it crosses in a documented box (docs/04 §8).
        let boxed = UncheckedSendableBox(connection)
        let resultData = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.request(on: boxed.value, fallback: fallback, invoke: invoke) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ClientError.timedOut }
            return first
        }
        return try JSONDecoder().decode(Response.self, from: resultData)
    }

    private nonisolated static func request(
        on connection: NSXPCConnection,
        fallback: VisionServiceError,
        invoke: @escaping @Sendable (any VisionServiceProtocol, @escaping @Sendable (Data?, (any Error)?) -> Void)
            -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Every path — a dead helper, a failed request, a reply — has to resume this
            // exactly once. An XPC connection that dies before replying is not an edge
            // case; it is what an idle helper exiting looks like from here, and leaving
            // the continuation unresumed would hang the capture flow forever.
            let resume = ResumeOnce(continuation)

            let service = connection.remoteObjectProxyWithErrorHandler { error in
                resume(.failure(error))
            } as? any VisionServiceProtocol

            guard let service else {
                resume(.failure(ClientError.helperUnavailable))
                return
            }
            invoke(service) { data, error in
                if let error {
                    resume(.failure(error))
                } else if let data {
                    resume(.success(data))
                } else {
                    resume(.failure(fallback))
                }
            }
        }
    }

    /// Drops the connection so the helper can start its idle countdown.
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: VisionServiceName.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: VisionServiceProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
            }
        }
        connection.interruptionHandler = { [weak self] in
            // Expected: this is what an idle helper exiting looks like from here.
            Task { @MainActor in
                self?.connection = nil
            }
        }
        connection.resume()
        return connection
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Carries a value that is safe to hand to one other task but is not marked `Sendable`.
private nonisolated struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Guards a continuation so it is resumed exactly once, whichever path gets there first.
private final nonisolated class ResumeOnce: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, any Error>
    private let lock = NSLock()
    private var hasResumed = false

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func callAsFunction(_ result: Result<Data, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(with: result)
    }
}
