import Foundation

/// Opening a library whose database cannot be read (docs/18 OUT-3).
///
/// An unreadable `history.sqlite` used to leave History silently empty for every launch
/// after. The database is only an index: every capture also has a JSON sidecar, so the
/// broken file is moved aside — kept, never deleted — and a fresh one is rebuilt from the
/// sidecars.
public extension HistoryStore {
    /// What opening found.
    struct Opening: Sendable {
        public let store: HistoryStore
        /// Where the unreadable database was moved, when it had to be. Nil for a normal open.
        public let setAside: URL?
        /// How many captures the rebuild brought back.
        public let recoveredCount: Int
    }

    /// Opens the library, rebuilding it from its sidecars when the database cannot be
    /// opened or migrated.
    nonisolated static func openRecovering(root: URL, tuning: Tuning = .agent) async throws -> Opening {
        do {
            return try Opening(store: open(root: root, tuning: tuning), setAside: nil, recoveredCount: 0)
        } catch {
            let layout = HistoryLayout(root: root)
            let setAside = try setAsideDatabase(at: layout.databaseURL)
            let store = try open(root: root, tuning: tuning)
            let recovered = try await store.rebuild()
            return Opening(store: store, setAside: setAside, recoveredCount: recovered)
        }
    }

    /// The agent's library, opened as `openRecovering(root:tuning:)` does.
    nonisolated static func openApplicationSupportRecovering(tuning: Tuning = .agent) async throws -> Opening {
        try await openRecovering(root: HistoryLayout.applicationSupport().root, tuning: tuning)
    }

    /// Moves the database and its WAL and shared-memory files beside it, under a dated
    /// name, so a fresh database can be made and the old one is still there to inspect.
    private nonisolated static func setAsideDatabase(at url: URL) throws -> URL {
        let manager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(base) unreadable \(stamp)")
            .appendingPathExtension(url.pathExtension)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.moveItem(at: source, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    }
}
