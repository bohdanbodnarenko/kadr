import Foundation

/// How an export reaches its destination without ever leaving it half-written (docs/18 STU-5).
///
/// The render goes to a hidden sibling and is swapped in only once it is whole, so a failed
/// or cancelled export of a file the user already had leaves that file alone, where the old
/// path deleted it before the first frame.
public enum StudioRenderPartialFile {
    /// `.<name>.partial-<uuid>.<ext>` beside `destination`: hidden, on the same volume, and
    /// with the real extension so the writer's file type stays right.
    public static func url(for destination: URL) -> URL {
        let name = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent()
            .appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
    }

    /// Moves a finished render over `destination`, replacing what was there in one step.
    public static func swapIntoPlace(_ partial: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try manager.moveItem(at: partial, to: destination)
        }
    }

    /// Whether `estimatedBytes`, with a margin, fits on the volume that holds `destination`.
    ///
    /// Nil when the volume will not say; the export then goes ahead, as it always did.
    public static func hasRoom(
        forEstimatedBytes estimatedBytes: Int,
        at destination: URL,
        margin: Double = 1.2
    ) -> Bool? {
        let folder = destination.deletingLastPathComponent()
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return fits(estimatedBytes: estimatedBytes, available: available, margin: margin)
    }

    /// The comparison itself, separate so a test can drive it.
    static func fits(estimatedBytes: Int, available: Int64, margin: Double) -> Bool {
        Double(estimatedBytes) * margin <= Double(available)
    }
}
