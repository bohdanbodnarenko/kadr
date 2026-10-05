import Foundation

/// JSON next to a capture so the SQLite index can be thrown away and rebuilt (docs/04 §9).
struct HistorySidecar: Codable, Sendable {
    var version: Int
    var id: UUID
    var contentHash: String
    var relativePath: String
    var thumbnailRelativePath: String
    var kind: HistoryItemKind
    var width: Int
    var height: Int
    var applicationName: String?
    var capturedAt: Date
    var lastAccessedAt: Date
    var byteSize: Int64
    var originalFilename: String
    /// Added in version 2; absent from older sidecars, which decode it as nil.
    var originalPath: String?

    static let currentVersion = 2

    init(_ record: HistoryRecord) {
        version = Self.currentVersion
        id = record.id
        contentHash = record.contentHash
        relativePath = record.relativePath
        thumbnailRelativePath = record.thumbnailRelativePath
        kind = record.kind
        width = record.width
        height = record.height
        applicationName = record.applicationName
        capturedAt = record.capturedAt
        lastAccessedAt = record.lastAccessedAt
        byteSize = record.byteSize
        originalFilename = record.originalFilename
        originalPath = record.originalPath
    }

    func record() -> HistoryRecord {
        HistoryRecord(
            id: id,
            contentHash: contentHash,
            relativePath: relativePath,
            thumbnailRelativePath: thumbnailRelativePath,
            kind: kind,
            width: width,
            height: height,
            applicationName: applicationName,
            capturedAt: capturedAt,
            lastAccessedAt: lastAccessedAt,
            byteSize: byteSize,
            originalFilename: originalFilename,
            originalPath: originalPath
        )
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func write(_ record: HistoryRecord, to url: URL) throws {
        do {
            let data = try encoder().encode(HistorySidecar(record))
            try data.write(to: url, options: .atomic)
        } catch {
            throw HistoryError.writeFailed(error.localizedDescription)
        }
    }

    static func read(from url: URL) throws -> HistoryRecord {
        let data = try Data(contentsOf: url)
        return try decoder().decode(HistorySidecar.self, from: data).record()
    }
}
