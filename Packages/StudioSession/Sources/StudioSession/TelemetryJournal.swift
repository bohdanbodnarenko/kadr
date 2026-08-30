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

    /// How much of the journal is read at a time.
    ///
    /// A flushed minute of 60 Hz pointer samples is roughly 150 KB, so a quarter-megabyte
    /// block holds one comfortably and rarely needs a second pass to complete a line.
    private static let readBlock = 256 * 1024

    /// Hands each flushed chunk to `body`, in order, without holding the file (docs/11 S2).
    ///
    /// The whole journal is never resident. `load()` used to read the entire file into one
    /// `Data`, split it, decode every line and concatenate the lot — so finalising an hour's
    /// recording had the raw JSON, the decoded arrays, the concatenation *and* the
    /// re-encoded sidecar all alive at the same moment. That is roughly 8.6 MB apiece: a
    /// 30-odd megabyte spike in the agent, at the exact instant the user presses Stop, in
    /// the process whose whole budget is 30 MB.
    ///
    /// A corrupt line is skipped rather than failing the load. A recording is worth more
    /// than the minute of pointer samples a bad write cost, and the alternative — refusing
    /// the whole sidecar — throws away fifty-nine good minutes to be strict about one.
    public func forEachChunk(_ body: (Chunk) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        var buffer = Data()
        var corrupt = 0

        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            do {
                try body(decoder.decode(Chunk.self, from: line))
            } catch {
                corrupt += 1
            }
        }

        while let block = try? handle.read(upToCount: Self.readBlock), !block.isEmpty {
            buffer.append(block)
            while let newline = buffer.firstIndex(of: 0x0A) {
                consume(Data(buffer[buffer.startIndex ..< newline]))
                buffer.removeSubrange(buffer.startIndex ... newline)
            }
        }
        // A final line the process never got to terminate — a crash mid-flush.
        consume(buffer)

        if corrupt > 0 {
            logger.error("Ignored \(corrupt, privacy: .public) corrupt telemetry chunk(s)")
        }
    }

    /// Every flushed chunk, in order. Missing file means nothing has been flushed yet.
    public func load() -> Chunk {
        var combined = Chunk()
        forEachChunk { chunk in
            combined.pointer.append(contentsOf: chunk.pointer)
            combined.clicks.append(contentsOf: chunk.clicks)
            combined.keystrokes.append(contentsOf: chunk.keystrokes)
        }
        return combined
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
