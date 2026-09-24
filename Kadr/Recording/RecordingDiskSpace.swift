import Foundation

/// Whether there is room to record at all (docs/17 T-REC-10).
///
/// A 5K60 HEVC take writes about 80 Mb/s — some 600 MB a minute — into the in-progress
/// folder, and the join then needs as much again in the save folder. Starting with less
/// than a few minutes' worth ends in a writer failure a minute in, so it is refused up front
/// with a reason the user can act on.
nonisolated enum RecordingDiskSpace {
    /// About two minutes of the heaviest recording Kadr makes.
    static let minimumBytes: Int64 = 1_500_000_000

    struct Shortage: LocalizedError, Equatable {
        let volumeName: String
        let availableBytes: Int64

        var errorDescription: String? {
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return String(
                localized: "Only \(available) is free on “\(volumeName)”. Free up some space, then record again."
            )
        }
    }

    /// The first volume among `folders` without room, if any. A volume whose capacity
    /// cannot be read is given the benefit of the doubt.
    static func shortage(
        in folders: [URL],
        available: (URL) -> (name: String, bytes: Int64)? = Self.availableCapacity
    ) -> Shortage? {
        for folder in folders {
            guard let volume = available(folder) else { continue }
            if volume.bytes < minimumBytes {
                return Shortage(volumeName: volume.name, availableBytes: volume.bytes)
            }
        }
        return nil
    }

    static func availableCapacity(of folder: URL) -> (name: String, bytes: Int64)? {
        // The folder may not exist yet; its volume is its nearest existing ancestor's.
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedNameKey
        ])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return (values?.volumeLocalizedName ?? url.lastPathComponent, bytes)
    }
}
