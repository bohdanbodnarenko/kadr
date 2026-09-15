import Foundation

/// The editor moved a capture to the Trash (docs/03 §3).
///
/// The editor and the agent are separate processes, and a capture's overlay card and its
/// History copy belong to the agent. So the editor trashes the file and says so, and the
/// agent drops the card and purges the copy the way deleting from the card does.
///
/// A distributed notification is local IPC through the notification server; nothing leaves
/// the Mac (CLAUDE.md rule 1). The paths ride in `object` as a JSON string rather than in
/// `userInfo`, which the system strips for sandboxed senders and receivers.
public enum CaptureDeletionNotice {
    public static let name = Notification.Name("app.kadr.capture.movedToTrash")

    public struct Paths: Equatable, Sendable {
        /// Where the capture was, which is what an overlay card points at.
        public let original: URL
        /// Where it is now. History's copy is matched by content, so it is hashed from here.
        public let trashed: URL

        public init(original: URL, trashed: URL) {
            self.original = original
            self.trashed = trashed
        }
    }

    public static func encode(_ paths: Paths) -> String? {
        guard let data = try? JSONEncoder().encode([paths.original.path, paths.trashed.path]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The paths a notice carries, or nil for anything that is not a well-formed notice.
    public static func decode(_ object: Any?) -> Paths? {
        guard let string = object as? String,
              let data = string.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              paths.count == 2,
              paths.allSatisfy({ $0.hasPrefix("/") })
        else { return nil }
        return Paths(
            original: URL(fileURLWithPath: paths[0]),
            trashed: URL(fileURLWithPath: paths[1])
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

    /// Whether a path is inside a Trash — the only place a genuine notice points.
    ///
    /// The home Trash is `~/.Trash`; other volumes keep theirs in `/.Trashes/<uid>`.
    public static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }
}
