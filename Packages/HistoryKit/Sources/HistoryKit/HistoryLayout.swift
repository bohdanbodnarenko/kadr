import Foundation

/// On-disk layout of the library (docs/04 §9).
///
/// ```
/// {root}/
///   Captures/{sha256}.{ext}     content-addressed media
///   Thumbnails/{sha256}.jpg     ImageIO-downsampled, same hash
///   Sidecars/{uuid}.json        rebuild source for the index
///   history.sqlite              disposable GRDB index
/// ```
public struct HistoryLayout: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var captures: URL {
        root.appendingPathComponent("Captures", isDirectory: true)
    }

    public var thumbnails: URL {
        root.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    public var sidecars: URL {
        root.appendingPathComponent("Sidecars", isDirectory: true)
    }

    public var databaseURL: URL {
        root.appendingPathComponent("history.sqlite", isDirectory: false)
    }

    public func captureURL(hash: String, fileExtension: String) -> URL {
        captures.appendingPathComponent("\(hash).\(fileExtension)", isDirectory: false)
    }

    public func thumbnailURL(hash: String) -> URL {
        thumbnails.appendingPathComponent("\(hash).jpg", isDirectory: false)
    }

    public func sidecarURL(id: UUID) -> URL {
        sidecars.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    public func url(forRelativePath path: String) -> URL {
        root.appendingPathComponent(path, isDirectory: false)
    }

    public func relativePath(for url: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    /// `~/Library/Application Support/Kadr`, creating nothing.
    public static func applicationSupport() throws -> HistoryLayout {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw HistoryError.rootUnavailable
        }
        return HistoryLayout(root: appSupport.appendingPathComponent("Kadr", isDirectory: true))
    }

    public func prepare() throws {
        let manager = FileManager.default
        for directory in [root, captures, thumbnails, sidecars] {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw HistoryError.writeFailed(error.localizedDescription)
            }
        }
    }
}
