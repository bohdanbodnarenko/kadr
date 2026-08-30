import Foundation
import os
import Shared

/// Append-only chunks of pointer telemetry, so a long recording cannot grow the in-memory
/// arrays without bound (docs/10 R2.5).
///
/// The canonical sidecar is still `input.json`, written once when the recording stops.
/// While it runs, each flushed minute is one JSON line here — cheap to append, cheap to
/// drop from RAM, and recoverable if the process dies before the final write.
public struct TelemetryJournal: Sendable {
    public let url: URL
    private let logger = KadrLog.logger(.recording)

    public init(url: URL) {
        self.url = url
    }

    /// One flushed minute of samples.
    public struct Chunk: Codable, Sendable {
        public var pointer: [PointerSample]
        public var clicks: [ClickEvent]
        public var keystrokes: [KeystrokeEvent]

        public init(
            pointer: [PointerSample] = [],
            clicks: [ClickEvent] = [],
            keystrokes: [KeystrokeEvent] = []
        ) {
            self.pointer = pointer
            self.clicks = clicks
            self.keystrokes = keystrokes
        }

        public var isEmpty: Bool {
            pointer.isEmpty && clicks.isEmpty && keystrokes.isEmpty
        }
    }

    /// Appends a chunk. No-op when every array is empty, so a quiet minute costs nothing.
    public func append(_ chunk: Chunk) throws {
        guard !chunk.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(chunk)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    /// Every flushed chunk, in order. Missing file means nothing has been flushed yet.
    public func load() -> Chunk {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return Chunk()
        }
        var combined = Chunk()
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            do {
                let chunk = try decoder.decode(Chunk.self, from: Data(line))
                combined.pointer.append(contentsOf: chunk.pointer)
                combined.clicks.append(contentsOf: chunk.clicks)
                combined.keystrokes.append(contentsOf: chunk.keystrokes)
            } catch {
                logger.error("Ignoring a corrupt telemetry chunk: \(error.localizedDescription, privacy: .public)")
            }
        }
        return combined
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
