import CryptoKit
import Foundation

/// SHA-256 of a file, streamed so a recording never has to fit in RAM.
enum HistoryContentAddress {
    static let chunkSize = 1024 * 1024

    static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies `from` to `to` unless the destination already exists (same hash, same bytes).
    static func install(from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: to.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: from, to: to)
        } catch {
            throw HistoryError.writeFailed(error.localizedDescription)
        }
    }
}
