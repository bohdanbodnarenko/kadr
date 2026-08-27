import Foundation
import Shared

/// What a history item is, for filters and for choosing a thumbnail path (docs/03 §5).
public enum HistoryItemKind: String, Sendable, Codable, CaseIterable, Hashable {
    case image
    case video
    case scrolling

    public var title: String {
        switch self {
        case .image: "Images"
        case .video: "Recordings"
        case .scrolling: "Scrolling"
        }
    }
}

/// One capture in the library: the SQLite row and the sidecar payload (docs/03 §5, docs/04 §9).
///
/// The file itself is content-addressed and may be shared by several records; this type
/// is the per-capture event (app, time, original name). The database is disposable —
/// everything here is also written next to the file as JSON.
public struct HistoryRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var contentHash: String
    /// Path relative to the history root, e.g. `Captures/ab…png`.
    public var relativePath: String
    public var thumbnailRelativePath: String
    public var kind: HistoryItemKind
    public var width: Int
    public var height: Int
    public var applicationName: String?
    public var capturedAt: Date
    public var lastAccessedAt: Date
    public var byteSize: Int64
    public var originalFilename: String

    public init(
        id: UUID = UUID(),
        contentHash: String,
        relativePath: String,
        thumbnailRelativePath: String,
        kind: HistoryItemKind,
        width: Int,
        height: Int,
        applicationName: String?,
        capturedAt: Date,
        lastAccessedAt: Date,
        byteSize: Int64,
        originalFilename: String
    ) {
        self.id = id
        self.contentHash = contentHash
        self.relativePath = relativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.kind = kind
        self.width = width
        self.height = height
        self.applicationName = applicationName
        self.capturedAt = capturedAt
        self.lastAccessedAt = lastAccessedAt
        self.byteSize = byteSize
        self.originalFilename = originalFilename
    }

    public var pixelSize: PixelSize {
        PixelSize(width: width, height: height)
    }
}

/// What to copy into the library (docs/03 §5).
public struct HistoryIngest: Sendable {
    public var sourceURL: URL
    public var kind: HistoryItemKind
    public var pixelSize: PixelSize
    public var applicationName: String?
    public var capturedAt: Date
    public var originalFilename: String
    /// For recordings, a still ImageIO can read. Images generate their own thumbnail.
    public var thumbnailSourceURL: URL?

    public init(
        sourceURL: URL,
        kind: HistoryItemKind,
        pixelSize: PixelSize,
        applicationName: String? = nil,
        capturedAt: Date = Date(),
        originalFilename: String,
        thumbnailSourceURL: URL? = nil
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.pixelSize = pixelSize
        self.applicationName = applicationName
        self.capturedAt = capturedAt
        self.originalFilename = originalFilename
        self.thumbnailSourceURL = thumbnailSourceURL
    }
}

/// Query for the history browser (docs/03 §5).
public struct HistoryFilter: Sendable, Hashable {
    public var kind: HistoryItemKind?
    public var capturedAfter: Date?
    public var capturedBefore: Date?

    public init(kind: HistoryItemKind? = nil, capturedAfter: Date? = nil, capturedBefore: Date? = nil) {
        self.kind = kind
        self.capturedAfter = capturedAfter
        self.capturedBefore = capturedBefore
    }

    public static let all = HistoryFilter()
}

/// Retention + size cap, as HistoryKit understands them (docs/03 §5).
///
/// SettingsKit owns the user-facing enums; the app maps those onto this value so this
/// package never imports a sibling layer-1 module.
public struct HistoryPolicy: Sendable, Hashable {
    /// Delete items older than this. `nil` means keep forever (until the size cap).
    public var maxAge: TimeInterval?
    /// LRU-evict until the library is at or under this. `nil` means no cap.
    public var sizeCapBytes: Int64?
    /// When set, anything captured before this instant is treated as a previous session.
    public var sessionStartedAt: Date?

    public init(maxAge: TimeInterval? = nil, sizeCapBytes: Int64? = nil, sessionStartedAt: Date? = nil) {
        self.maxAge = maxAge
        self.sizeCapBytes = sizeCapBytes
        self.sessionStartedAt = sessionStartedAt
    }

    public static let keepForever = HistoryPolicy()
}

/// Bytes and count currently on disk in the library.
public struct HistoryStorageUsage: Sendable, Hashable {
    public var itemCount: Int
    public var byteCount: Int64

    public init(itemCount: Int, byteCount: Int64) {
        self.itemCount = itemCount
        self.byteCount = byteCount
    }

    public static let zero = HistoryStorageUsage(itemCount: 0, byteCount: 0)
}

/// What a retention pass deleted.
public struct EvictionReport: Sendable, Hashable {
    public var deletedCount: Int
    public var freedBytes: Int64

    public init(deletedCount: Int = 0, freedBytes: Int64 = 0) {
        self.deletedCount = deletedCount
        self.freedBytes = freedBytes
    }

    public static let empty = EvictionReport()
}

/// Failures talking to the library. Never silent: the overlay still works without history.
public enum HistoryError: Error, Sendable {
    case rootUnavailable
    case sourceMissing(URL)
    case writeFailed(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .rootUnavailable:
            "Could not create the history folder"
        case let .sourceMissing(url):
            "Capture file is gone: \(url.lastPathComponent)"
        case let .writeFailed(message), let .database(message):
            message
        }
    }
}

extension HistoryError: LocalizedError {}
