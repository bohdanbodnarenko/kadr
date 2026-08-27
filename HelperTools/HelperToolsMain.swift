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
final class VisionService: NSObject, VisionServiceProtocol {
    private let recognizer = TextRecognizer()
    private let gifEncoder = ImageIOGIFEncoder()
    private let logger = KadrLog.logger(.capture)

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
                let response: GIFResponse = if request.estimateOnly {
                    try await GIFResponse(
                        path: nil,
                        byteCount: encoder.estimatedSize(ofMovieAt: source, options: options)
                    )
                } else {
                    try await {
                        let url = try await encoder.encode(movieAt: source, to: destination, options: options)
                        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        return GIFResponse(path: url.path, byteCount: bytes)
                    }()
                }
                try reply(JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error)
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
        connection.exportedInterface = NSXPCInterface(with: VisionServiceProtocol.self)
        connection.exportedObject = VisionService()
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
