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
        let connection = connection ?? makeConnection()
        self.connection = connection

        // `NSXPCConnection` is not `Sendable`; it is used only from the request task,
        // which is the single consumer, so it crosses in a documented box (docs/04 §8).
        let boxed = UncheckedSendableBox(connection)
        let resultData = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.request(pngData, optionsData, on: boxed.value) }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ClientError.timedOut }
            return first
        }
        return try JSONDecoder().decode(VisionAnalysis.self, from: resultData)
    }

    private nonisolated static func request(
        _ pngData: Data,
        _ optionsData: Data,
        on connection: NSXPCConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Every path — a dead helper, a failed request, a reply — has to resume this
            // exactly once. An XPC connection that dies before replying is not an edge
            // case; it is what an idle helper exiting looks like from here, and leaving
            // the continuation unresumed would hang the capture flow forever.
            let resume = ResumeOnce(continuation)

            let service = connection.remoteObjectProxyWithErrorHandler { error in
                resume.callAsFunction(.failure(error))
            } as? any VisionServiceProtocol

            guard let service else {
                resume(.failure(ClientError.helperUnavailable))
                return
            }

            service.analyze(imageData: pngData, optionsData: optionsData) { data, error in
                if let error {
                    resume(.failure(error))
                } else if let data {
                    resume(.success(data))
                } else {
                    resume(.failure(VisionServiceError.recognitionFailed))
                }
            }
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
        let connection = connection ?? makeConnection()
        self.connection = connection

        let boxed = UncheckedSendableBox(connection)
        let resultData = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.requestGIF(requestData, on: boxed.value) }
            group.addTask {
                // Encoding a long recording legitimately takes a while, so this bound is
                // far more generous than the recognition one — it exists to catch a dead
                // helper, not a slow encode.
                try await Task.sleep(for: .seconds(600))
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ClientError.timedOut }
            return first
        }
        return try JSONDecoder().decode(GIFResponse.self, from: resultData)
    }

    private nonisolated static func requestGIF(
        _ requestData: Data,
        on connection: NSXPCConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { error in
                resume(.failure(error))
            } as? any VisionServiceProtocol

            guard let service else {
                resume(.failure(ClientError.helperUnavailable))
                return
            }
            service.encodeGIF(requestData: requestData) { data, error in
                if let error {
                    resume(.failure(error))
                } else if let data {
                    resume(.success(data))
                } else {
                    resume(.failure(VisionServiceError.recognitionFailed))
                }
            }
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
        let connection = connection ?? makeConnection()
        self.connection = connection

        let boxed = UncheckedSendableBox(connection)
        let resultData = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.requestStitch(requestData, on: boxed.value) }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ClientError.timedOut }
            return first
        }
        return try JSONDecoder().decode(ScrollStitchResponse.self, from: resultData)
    }

    private nonisolated static func requestStitch(
        _ requestData: Data,
        on connection: NSXPCConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { error in
                resume(.failure(error))
            } as? any VisionServiceProtocol

            guard let service else {
                resume(.failure(ClientError.helperUnavailable))
                return
            }
            service.stitchScroll(requestData: requestData) { data, error in
                if let error {
                    resume(.failure(error))
                } else if let data {
                    resume(.success(data))
                } else {
                    resume(.failure(VisionServiceError.stitchFailed))
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
