import Foundation

/// Moving or copying onto a path the user agreed to replace, without a window where neither
/// file exists (docs/18 §4.3 P3).
///
/// Removing the destination and then moving lost the user's file whenever the move failed
/// after the delete, on a full disk or a volume that went away. `replaceItemAt` swaps the
/// two in one step and leaves the original in place if it cannot.
public enum FileReplacement {
    /// Moves `source` to `destination`, replacing a file already there.
    @discardableResult
    public static func move(_ source: URL, to destination: URL) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else {
            try manager.moveItem(at: source, to: destination)
            return destination
        }
        return try manager.replaceItemAt(destination, withItemAt: source) ?? destination
    }

    /// Copies `source` to `destination`, replacing a file already there. The copy is
    /// made beside the destination first, so the replace is a rename on one volume.
    @discardableResult
    public static func copy(_ source: URL, to destination: URL) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else {
            try manager.copyItem(at: source, to: destination)
            return destination
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        try manager.copyItem(at: source, to: staging)
        do {
            return try manager.replaceItemAt(destination, withItemAt: staging) ?? destination
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
}
