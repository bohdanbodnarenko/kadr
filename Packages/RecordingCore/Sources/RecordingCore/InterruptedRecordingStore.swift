import Foundation

/// Locates the temporary session folders a crash left behind (docs/03 §1.8).
///
/// Each in-flight recording writes its pause/resume segments into one
/// `Kadr-Recording-<uuid>` directory. The engine deletes that folder after a clean stop;
/// a process that dies first leaves playable `segment-*.mp4` files that launch can stitch
/// back into History.
public enum InterruptedRecordingStore {
    public static let directoryPrefix = "Kadr-Recording-"
    public static let segmentPrefix = "segment-"

    /// Session folders under a temporary or in-progress root.
    public static func directories(
        in temporaryDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        directories(in: [temporaryDirectory], fileManager: fileManager)
    }

    /// Session folders under any of the given roots (docs/16 REC-7).
    public static func directories(
        in roots: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        roots.flatMap { root in
            let contents = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter { url in
                url.lastPathComponent.hasPrefix(directoryPrefix) && isDirectory(url)
            }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `~/Library/Application Support/Kadr/InProgress` — recordings in flight live here
    /// rather than `$TMPDIR`, which macOS may purge (docs/16 REC-7).
    public static func inProgressRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("Kadr", isDirectory: true)
            .appendingPathComponent("InProgress", isDirectory: true)
    }

    /// Segment files in recording order.
    public static func segmentFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { url in
                url.lastPathComponent.hasPrefix(segmentPrefix) && url.pathExtension.lowercased() == "mp4"
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
