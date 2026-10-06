import Foundation

/// The editor wrote a capture, so the agent can refresh the card, History and clipboard
/// (docs/16 OUT-4).
///
/// A distributed notification is local IPC through the notification server; nothing
/// leaves the Mac (CLAUDE.md rule 1). Paths ride in `object` as JSON, matching
/// `CaptureDeletionNotice`.
public enum CaptureSavedNotice {
    public static let name = Notification.Name("com.bohdanbodnarenko.kadr.capture.saved")

    public struct Paths: Equatable, Sendable {
        /// Where the capture was when the editor opened it.
        public let original: URL
        /// Where the flattened save landed (overwrite or sibling).
        public let saved: URL
        /// Content hash of the original bytes before an in-place overwrite, if known.
        public let previousHash: String?

        public init(original: URL, saved: URL, previousHash: String? = nil) {
            self.original = original
            self.saved = saved
            self.previousHash = previousHash
        }

        /// Both files exist, and the save is next to the original or in `saveFolder`.
        public func isValid(saveFolder: URL? = nil) -> Bool {
            let manager = FileManager.default
            guard manager.fileExists(atPath: original.path),
                  manager.fileExists(atPath: saved.path)
            else {
                return false
            }
            let savedDirectory = saved.deletingLastPathComponent().standardizedFileURL
            let originalDirectory = original.deletingLastPathComponent().standardizedFileURL
            if savedDirectory == originalDirectory {
                return true
            }
            if let saveFolder, savedDirectory == saveFolder.standardizedFileURL {
                return true
            }
            return false
        }
    }

    public static func encode(_ paths: Paths) -> String? {
        var payload: [String] = [paths.original.path, paths.saved.path]
        if let hash = paths.previousHash {
            payload.append(hash)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ object: Any?) -> Paths? {
        guard let string = object as? String,
              let data = string.data(using: .utf8),
              let parts = try? JSONDecoder().decode([String].self, from: data),
              parts.count == 2 || parts.count == 3,
              parts[0].hasPrefix("/"),
              parts[1].hasPrefix("/")
        else { return nil }
        return Paths(
            original: URL(fileURLWithPath: parts[0]),
            saved: URL(fileURLWithPath: parts[1]),
            previousHash: parts.count == 3 ? parts[2] : nil
        )
    }

    public static func post(_ paths: Paths) {
        guard let object = encode(paths) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: object,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
