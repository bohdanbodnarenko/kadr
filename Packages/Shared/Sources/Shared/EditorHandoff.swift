import CryptoKit
import Foundation

/// The agent telling the editor "this file is mine, edit it where it is" (docs/18 ED-1).
///
/// The editor copies any image that arrives from outside Kadr into a hidden imports folder, so
/// a Finder double-click can never touch the original. A capture the agent hands over must be
/// edited in place instead, or ⌘S and Move to Trash act on a copy the user cannot see. Both
/// arrive through the same `application(_:open:)`, and launch arguments are dropped when the
/// editor is already running, so the agent leaves a marker file keyed by the capture's path
/// just before opening it; the editor consumes the marker on open.
///
/// A marker is valid for `lifetime` only, so a hand-off that never arrived cannot make a later
/// Finder open of the same path skip the copy.
public struct EditorHandoff: Sendable {
    /// Where the markers live: one small file per pending hand-off.
    public let directory: URL
    /// How long a marker stays valid after it is written.
    public let lifetime: TimeInterval

    public init(directory: URL = EditorHandoff.defaultDirectory, lifetime: TimeInterval = 120) {
        self.directory = directory
        self.lifetime = lifetime
    }

    /// `~/Library/Application Support/Kadr/Handoff`, shared by the agent and the editor.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Kadr/Handoff", isDirectory: true)
    }

    /// Records that the agent is about to open `file` in the editor.
    public func mark(_ file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.key(for: file).utf8).write(to: marker(for: file), options: .atomic)
    }

    /// Whether `file` was handed over by the agent within `lifetime`. Removes the marker, so
    /// each hand-off is honoured once.
    public func consume(_ file: URL, now: Date = Date()) -> Bool {
        let marker = marker(for: file)
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: marker.path),
              let written = attributes[.modificationDate] as? Date
        else { return false }
        try? manager.removeItem(at: marker)
        let age = now.timeIntervalSince(written)
        return age >= -1 && age <= lifetime
    }

    /// Deletes markers older than `lifetime`. Returns how many went.
    @discardableResult
    public func sweepExpired(now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for entry in entries {
            let written = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(written) > lifetime else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    private func marker(for file: URL) -> URL {
        let digest = SHA256.hash(data: Data(Self.key(for: file).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("handoff")
    }

    private static func key(for file: URL) -> String {
        file.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
