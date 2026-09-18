import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// Dragging a card out has to survive the card (docs/03 §2, §6; docs/07 C1).
///
/// The receiver asks for the bytes after the drop — after the dragging session ended, and
/// with dismiss-on-drag on, after the card and everything it owned has been torn down. These
/// cover that ordering, because it is the ordering that made every drop arrive empty.
@MainActor
@Suite("File promise drags")
struct FilePromiseDragTests {
    /// Writes a file to drag, and hands back where it is.
    private func stagedFile(named name: String, contents: String = "kadr") throws -> URL {
        let url = temporaryDirectory("promise").appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func payload(for url: URL, stable: Bool = false) -> FilePromisePayload {
        FilePromisePayload(
            suggestedName: url.lastPathComponent,
            contentType: UTType(filenameExtension: url.pathExtension) ?? .data,
            resolve: { url },
            stableFileURL: stable ? url : nil
        )
    }

    @Test("The provider keeps its own delegate alive")
    func providerOwnsItsDelegate() throws {
        let source = try stagedFile(named: "shot.png")
        // `NSFilePromiseProvider.delegate` is weak, so a delegate owned by the card would
        // already be nil here — and a nil delegate can hand over nothing.
        let provider = KadrFilePromiseProvider(payload: payload(for: source))

        let delegate = try #require(provider.delegate)
        #expect(
            delegate.filePromiseProvider(provider, fileNameForType: UTType.png.identifier)
                == "shot.png"
        )
    }

    @Test("The promise is fulfilled with nothing but the provider left holding it")
    func writesWithOnlyTheProviderLeft() async throws {
        let source = try stagedFile(named: "shot.png", contents: "pixels")
        // Everything the drag started with is gone by the time the receiver asks — the
        // session has ended and the card may already have been dismissed. The provider,
        // which the pasteboard holds, is the last thing standing.
        let provider = KadrFilePromiseProvider(
            payload: FilePromisePayload(
                suggestedName: "shot.png",
                contentType: .png,
                resolve: { source }
            )
        )

        let destination = temporaryDirectory("drop").appendingPathComponent("shot.png")
        let delegate = try #require(provider.delegate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        #expect(try String(contentsOf: destination, encoding: .utf8) == "pixels")
    }

    @Test("A staged capture advertises the promise only")
    func stagedCaptureHasNoFileURLFlavour() throws {
        let source = try stagedFile(named: "staged.png")
        let provider = KadrFilePromiseProvider(payload: payload(for: source))

        #expect(!provider.writableTypes(for: NSPasteboard.general).contains(.fileURL))
    }

    @Test("A saved capture also drops as a path")
    func savedCaptureCarriesAFileURL() throws {
        let source = try stagedFile(named: "saved.png")
        let provider = KadrFilePromiseProvider(payload: payload(for: source, stable: true))

        #expect(provider.writableTypes(for: NSPasteboard.general).contains(.fileURL))
        // Round-trips the way a receiver reads it, rather than as a bare string.
        let list = try #require(provider.pasteboardPropertyList(forType: .fileURL))
        let read = NSURL(pasteboardPropertyList: list, ofType: .fileURL) as URL?
        #expect(read?.standardizedFileURL == source.standardizedFileURL)
    }
}
