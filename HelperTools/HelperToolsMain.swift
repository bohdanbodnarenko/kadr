import Foundation
import MediaExport
import os
import Shared
import VisionServices

/// The helper process (docs/04 §1).
///
/// A separate process whose entire reason for existing is that it can *stop* existing.
/// Vision's models cost tens of megabytes on first load and a GIF encode holds every
/// frame it is working on; nothing in AppKit gives that back. Process exit does, so the
/// helper counts its in-flight work and terminates once it has been idle for 30 seconds.
///
/// It receives pixels and file paths, and returns text and files. It never touches
/// ScreenCaptureKit — every capture call stays in the agent so the Screen Recording grant
/// attaches to the app the user actually sees (docs/04 §1).
final class VisionService: NSObject, VisionServiceProtocol, @unchecked Sendable {
    private let recognizer = TextRecognizer()
    private let gifEncoder = ImageIOGIFEncoder()
    private let stitcher = ScrollStitcher()
    private let historyIndexer = HistoryTextIndexer()
    private let subjectMasker = SubjectMaskGenerator()
    private let logger = KadrLog.logger(.capture)
    private var liveSpeech: LiveSpeechEngine?
    private weak var connection: NSXPCConnection?
    private var speechTask: Task<Void, Never>?
    private var liveIsRunning = false

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    private var speechClient: SpeechClientProtocol? {
        connection?.remoteObjectProxy as? SpeechClientProtocol
    }

    /// Re-encodes a capture smaller (docs/09 U2.4).
    ///
    /// Here rather than in the agent because the search decodes the capture and encodes it
    /// several times over — the memory the agent must not be spending (docs/04 §7 rule 4).
    /// The helper's idle countdown covers the whole thing, so it exits once the card is
    /// done with it.
    func compressImage(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()

        let request: CompressRequest
        do {
            request = try JSONDecoder().decode(CompressRequest.self, from: requestData)
        } catch {
            IdleTerminator.shared.endTransaction()
            reply(nil, VisionServiceError.invalidRequest)
            return
        }

        Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                let format = CompressedImageFormat(rawValue: request.format) ?? .heic
                let result = try ImageCompressor().compress(
                    fileAt: URL(fileURLWithPath: request.sourcePath),
                    options: CompressionOptions(targetBytes: request.targetBytes, format: format)
                )
                let destination = URL(fileURLWithPath: request.destinationPath)
                try result.data.write(to: destination, options: .atomic)

                let response = CompressResponse(
                    path: destination.path,
                    originalBytes: result.originalBytes,
                    compressedBytes: result.compressedBytes,
                    quality: result.quality
                )
                try reply(JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func encodeGIF(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()

        let request: GIFRequest
        do {
            request = try JSONDecoder().decode(GIFRequest.self, from: requestData)
        } catch {
            IdleTerminator.shared.endTransaction()
            reply(nil, VisionServiceError.invalidRequest)
            return
        }

        let encoder = gifEncoder
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            let source = URL(fileURLWithPath: request.sourcePath)
            let destination = URL(fileURLWithPath: request.destinationPath)
            let options = GIFOptions(frameRate: request.frameRate, maximumWidth: request.maximumWidth)

            do {
                // Both paths report the plan: a long recording is encoded at a lower rate,
                // a smaller size or a shorter length to fit memory, and the caller has to
                // be able to say so before the user commits (docs/07 M10).
                let plan = try await encoder.plan(forMovieAt: source, options: options)
                let response: GIFResponse = if request.estimateOnly {
                    try await GIFResponse(
                        path: nil,
                        byteCount: encoder.estimatedSize(ofMovieAt: source, options: options),
                        frameRate: plan.frameRate,
                        maximumWidth: plan.maximumWidth,
                        encodedSeconds: plan.encodedSeconds,
                        sourceSeconds: plan.sourceSeconds
                    )
                } else {
                    try await {
                        let url = try await encoder.encode(movieAt: source, to: destination, options: options)
                        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        return GIFResponse(
                            path: url.path,
                            byteCount: bytes,
                            frameRate: plan.frameRate,
                            maximumWidth: plan.maximumWidth,
                            encodedSeconds: plan.encodedSeconds,
                            sourceSeconds: plan.sourceSeconds
                        )
                    }()
                }
                try reply(JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func stitchScroll(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()

        let request: ScrollStitchRequest
        do {
            request = try JSONDecoder().decode(ScrollStitchRequest.self, from: requestData)
        } catch {
            IdleTerminator.shared.endTransaction()
            reply(nil, VisionServiceError.invalidRequest)
            return
        }

        let stitcher = stitcher
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            let excluded = Set(request.excludedFrames)
            let frames = request.framePaths.enumerated()
                .filter { !excluded.contains($0.offset) }
                .map { URL(fileURLWithPath: $0.element) }
            guard frames.count >= 2 else {
                reply(nil, VisionServiceError.notEnoughFrames)
                return
            }

            do {
                let response = try stitcher.stitch(
                    frames: frames,
                    to: URL(fileURLWithPath: request.destinationPath),
                    axis: request.axis,
                    memoryMappedThreshold: request.memoryMappedThreshold
                )
                try reply(JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, VisionServiceError.stitchFailed)
            }
        }
    }

    func analyze(
        imageData: Data,
        optionsData: Data,
        reply: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        IdleTerminator.shared.beginTransaction()

        let options: TextRecognitionOptions
        do {
            options = try JSONDecoder().decode(TextRecognitionOptions.self, from: optionsData)
        } catch {
            IdleTerminator.shared.endTransaction()
            reply(nil, VisionServiceError.invalidRequest)
            return
        }

        let recognizer = recognizer
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                let analysis = try await recognizer.analyze(pngData: imageData, options: options)
                try reply(JSONEncoder().encode(analysis), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func subjectMask(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()

        let request: SubjectMaskRequest
        do {
            request = try JSONDecoder().decode(SubjectMaskRequest.self, from: requestData)
        } catch {
            IdleTerminator.shared.endTransaction()
            reply(nil, VisionServiceError.invalidRequest)
            return
        }

        let masker = subjectMasker
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                let response = try masker.writeMask(
                    of: URL(fileURLWithPath: request.sourcePath),
                    to: URL(fileURLWithPath: request.destinationPath)
                )
                try reply(JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func indexHistory(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()

        let request: HistoryIndexRequest
        do {
            request = try JSONDecoder().decode(HistoryIndexRequest.self, from: requestData)
        } catch {
            IdleTerminator.shared.endTransaction()
            reply(nil, VisionServiceError.invalidRequest)
            return
        }

        let indexer = historyIndexer
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                let response = await indexer.run(request)
                try reply(JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func transcribe(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()
        SpeechModelLifecycle.shared.begin()
        speechTask?.cancel()
        let client = speechClient
        speechTask = Task {
            defer {
                IdleTerminator.shared.endTransaction()
                SpeechModelLifecycle.shared.end()
            }
            do {
                let data = try await SpeechXPCHandler.transcribe(requestData: requestData) { fraction in
                    client?.speechDidProgress(fraction)
                }
                try Task.checkCancellation()
                reply(data, nil)
            } catch is CancellationError {
                reply(nil, CancellationError())
            } catch {
                reply(nil, error)
            }
        }
    }

    func speechStatus(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                try await reply(SpeechXPCHandler.status(requestData: requestData), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func installSpeechModel(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()
        speechTask?.cancel()
        let client = speechClient
        speechTask = Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                let data = try await SpeechXPCHandler.install(requestData: requestData) { fraction in
                    client?.speechDidProgress(fraction)
                }
                try Task.checkCancellation()
                reply(data, nil)
            } catch is CancellationError {
                reply(nil, CancellationError())
            } catch {
                reply(nil, error)
            }
        }
    }

    func cancelSpeech() {
        speechTask?.cancel()
        speechTask = nil
    }

    func warmUpSpeech(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        IdleTerminator.shared.beginTransaction()
        Task {
            defer { IdleTerminator.shared.endTransaction() }
            do {
                try await reply(SpeechXPCHandler.warmUp(requestData: requestData), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    func startLiveSpeech(requestData: Data, reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        if !liveIsRunning {
            IdleTerminator.shared.beginTransaction()
            liveIsRunning = true
        }
        let client = speechClient
        Task {
            // Asked here so the prompt names this process's display name, not a framework
            // the agent must not load (docs/13 T1.1). The agent never imports Speech.
            let authorized = await SpeechXPCHandler.requestAuthorization()
            guard authorized else {
                self.stopLiveSpeech()
                reply(nil, VisionServiceError.speechUnavailable)
                return
            }
            let engine = LiveSpeechEngine()
            self.liveSpeech = engine
            do {
                let request = try JSONDecoder().decode(SpeechLiveStartRequest.self, from: requestData)
                try engine.start(
                    locale: Locale(identifier: request.localeIdentifier),
                    sampleRate: request.sampleRate
                ) { hypothesis in
                    if let data = try? JSONEncoder().encode(hypothesis) {
                        client?.speechDidHypothesize(data)
                    }
                }
                reply(Data(), nil)
            } catch {
                self.stopLiveSpeech()
                reply(nil, error)
            }
        }
    }

    func feedLiveSpeechAudio(_ pcmData: Data) {
        liveSpeech?.append(pcm: pcmData)
    }

    func stopLiveSpeech() {
        liveSpeech?.stop()
        liveSpeech = nil
        guard liveIsRunning else { return }
        liveIsRunning = false
        IdleTerminator.shared.endTransaction()
    }
}

/// Terminates the process once nothing has needed it for a while (docs/04 §1).
///
/// Reference counted rather than timer-only: a long recognition must not be killed
/// half-way because the clock ran out.
final class IdleTerminator: @unchecked Sendable {
    static let shared = IdleTerminator()

    private let queue = DispatchQueue(label: "app.kadr.helper.idle")
    private var activeTransactions = 0
    private var idleWork: DispatchWorkItem?
    private let logger = KadrLog.logger(.capture)

    private init() {}

    func beginTransaction() {
        queue.async {
            self.activeTransactions += 1
            self.idleWork?.cancel()
            self.idleWork = nil
        }
    }

    func endTransaction() {
        queue.async {
            self.activeTransactions = max(0, self.activeTransactions - 1)
            guard self.activeTransactions == 0 else { return }
            self.scheduleTermination()
        }
    }

    /// Starts the countdown; called at launch too, so a helper nobody talks to still goes.
    func scheduleTermination() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, activeTransactions == 0 else { return }
            logger.info("Vision helper idle; exiting to give its memory back")
            exit(0)
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + VisionServiceName.idleTimeout, execute: work)
    }
}

/// Vends the service to whoever connects.
///
/// `@unchecked Sendable` under a plain invariant: it holds no state at all. XPC calls the
/// delegate from its own queue, and every connection gets a fresh `VisionService`.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = VisionService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: VisionServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: SpeechClientProtocol.self)
        connection.exportedObject = service
        // The editor lets go of its connection to cancel (docs/17 T-STU-5): a cancel sent
        // on a fresh connection reached a fresh `VisionService` with nothing to stop, so a
        // cancelled Tidy kept burning CPU and a cancelled model download kept downloading.
        // Whatever this connection started ends with it.
        connection.invalidationHandler = {
            service.cancelSpeech()
            service.stopLiveSpeech()
        }
        connection.resume()
        return true
    }
}

/// The helper's entry point.
///
/// `@main` rather than top-level code in a `main.swift`: top-level globals are shared
/// mutable state under Swift 6 strict concurrency, and an XPC listener is exactly the
/// kind of thing that would need silencing rather than fixing.
@main
enum HelperToolsMain {
    /// Held for the process's lifetime; the listener does not retain its delegate.
    private static let delegate = ServiceDelegate()

    static func main() {
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        // Start the clock immediately: a helper nobody ever talks to should still go away.
        IdleTerminator.shared.scheduleTermination()
        listener.resume()
    }
}
