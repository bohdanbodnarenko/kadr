import CoreGraphics
import Foundation
import GRDB
import os
import Shared

/// Files + SQLite index for every capture (docs/03 §5, docs/04 §1, §9).
///
/// The actor is the only writer. The database can be deleted at any time: `rebuild()`
/// walks sidecars and files and puts the index back. Retention and the size cap run
/// on ingest and at launch — never on a timer, so idle CPU stays at zero.
public actor HistoryStore {
    public nonisolated let layout: HistoryLayout

    private let dbPool: DatabasePool
    private let logger = KadrLog.logger(.history)
    private let signposter = KadrLog.signposter(.history)
    private let loader = ThumbnailLoader()

    /// Opens (or creates) the library at `root`. Cheap: a few SQLite pages, no images.
    public nonisolated static func open(root: URL) throws -> HistoryStore {
        let layout = HistoryLayout(root: root)
        try layout.prepare()
        let pool = try HistoryDatabase.makePool(at: layout.databaseURL)
        do {
            try HistoryDatabase.migrator.migrate(pool)
        } catch {
            throw HistoryError.database(error.localizedDescription)
        }
        return HistoryStore(layout: layout, dbPool: pool)
    }

    /// Application Support library used by the agent.
    public nonisolated static func openApplicationSupport() throws -> HistoryStore {
        try open(root: HistoryLayout.applicationSupport().root)
    }

    private init(layout: HistoryLayout, dbPool: DatabasePool) {
        self.layout = layout
        self.dbPool = dbPool
    }

    public nonisolated func fileURL(for record: HistoryRecord) -> URL {
        layout.url(forRelativePath: record.relativePath)
    }

    public nonisolated func thumbnailFileURL(for record: HistoryRecord) -> URL {
        layout.url(forRelativePath: record.thumbnailRelativePath)
    }

    /// Copies a capture into the library, writes a sidecar and a thumbnail, indexes it.
    @discardableResult
    public func ingest(_ draft: HistoryIngest) async throws -> HistoryRecord {
        guard FileManager.default.fileExists(atPath: draft.sourceURL.path) else {
            throw HistoryError.sourceMissing(draft.sourceURL)
        }

        let hash = try HistoryContentAddress.hash(of: draft.sourceURL)
        let fileExtension = draft.sourceURL.pathExtension.isEmpty
            ? "png"
            : draft.sourceURL.pathExtension.lowercased()
        let captureURL = layout.captureURL(hash: hash, fileExtension: fileExtension)
        try HistoryContentAddress.install(from: draft.sourceURL, to: captureURL)

        let thumbURL = layout.thumbnailURL(hash: hash)
        let thumbSource = draft.thumbnailSourceURL ?? draft.sourceURL
        try HistoryThumbnailWriter.write(from: thumbSource, to: thumbURL)

        let byteSize = fileSize(captureURL)
        let record = HistoryRecord(
            contentHash: hash,
            relativePath: layout.relativePath(for: captureURL),
            thumbnailRelativePath: layout.relativePath(for: thumbURL),
            kind: draft.kind,
            width: draft.pixelSize.width,
            height: draft.pixelSize.height,
            applicationName: draft.applicationName,
            capturedAt: draft.capturedAt,
            lastAccessedAt: draft.capturedAt,
            byteSize: byteSize,
            originalFilename: draft.originalFilename
        )
        try HistorySidecar.write(record, to: layout.sidecarURL(id: record.id))
        try await insert(record)
        logger.info("Ingested \(record.originalFilename, privacy: .public)")
        return record
    }

    public func record(id: UUID) async throws -> HistoryRecord? {
        try await dbPool.read { db in
            try HistoryRecord.fetchOne(db, key: id.uuidString)
        }
    }

    /// Newest first. Used by the status-menu strip (docs/03 §5).
    public func recent(limit: Int) async throws -> [HistoryRecord] {
        try await loadPage(filter: .all, offset: 0, limit: limit)
    }

    /// Paged query for the history window. Offset 0 is the cold-open path (docs/03 §5).
    public func loadPage(filter: HistoryFilter, offset: Int, limit: Int) async throws -> [HistoryRecord] {
        let interval: OSSignpostIntervalState? = if offset == 0 {
            signposter.beginInterval("historyColdOpen")
        } else {
            nil
        }
        defer {
            if let interval {
                signposter.endInterval("historyColdOpen", interval)
            }
        }

        return try await dbPool.read { db in
            let request = Self.apply(filter, to: HistoryRecord.order(Column("captured_at").desc))
            return try request.limit(limit, offset: offset).fetchAll(db)
        }
    }

    /// Narrows a query by the browser's type and date pickers (docs/03 §5).
    ///
    /// Shared by browsing and searching so a filter cannot mean one thing in the grid and
    /// something else once the user types into the search field.
    static func apply(
        _ filter: HistoryFilter,
        to request: QueryInterfaceRequest<HistoryRecord>
    ) -> QueryInterfaceRequest<HistoryRecord> {
        var request = request
        if let kind = filter.kind {
            request = request.filter(Column("kind") == kind.rawValue)
        }
        if let after = filter.capturedAfter {
            request = request.filter(Column("captured_at") >= after)
        }
        if let before = filter.capturedBefore {
            request = request.filter(Column("captured_at") <= before)
        }
        return request
    }

    /// Database access for the search and indexing API in `HistoryIndexing.swift`.
    ///
    /// Internal rather than private: the actor is still the only writer, and keeping the
    /// pool itself unreachable is what makes that true.
    func read<Value: Sendable>(_ block: @Sendable @escaping (Database) throws -> Value) async throws -> Value {
        try await dbPool.read(block)
    }

    func write<Value: Sendable>(_ block: @Sendable @escaping (Database) throws -> Value) async throws -> Value {
        do {
            return try await dbPool.write(block)
        } catch {
            throw HistoryError.database(error.localizedDescription)
        }
    }

    /// ImageIO thumbnail of the *already downsampled* JPEG, never of the original capture.
    public nonisolated func thumbnail(for record: HistoryRecord, maxPixelSize: Int) -> CGImage? {
        loader.thumbnail(for: thumbnailFileURL(for: record), maxPixelSize: maxPixelSize)
    }

    public func markAccessed(id: UUID, at date: Date = Date()) async throws {
        _ = try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE capture_records SET last_accessed_at = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
        if var record = try await record(id: id) {
            record.lastAccessedAt = date
            try HistorySidecar.write(record, to: layout.sidecarURL(id: id))
        }
    }

    /// Deletes the records and, when nothing else shares the bytes, the files (docs/03 §5).
    public func delete(ids: [UUID]) async throws -> EvictionReport {
        var report = EvictionReport()
        for id in ids {
            let piece = try await deleteOne(id: id)
            report.deletedCount += piece.deletedCount
            report.freedBytes += piece.freedBytes
        }
        return report
    }

    public func storageUsage() async throws -> HistoryStorageUsage {
        try await dbPool.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_records") ?? 0
            let bytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_size), 0) FROM capture_records") ?? 0
            return HistoryStorageUsage(itemCount: count, byteCount: bytes)
        }
    }

    /// Time-based + LRU size-cap eviction (docs/03 §5).
    @discardableResult
    public func applyRetention(_ policy: HistoryPolicy, now: Date = Date()) async throws -> EvictionReport {
        var report = EvictionReport()
        var doomed: [UUID] = []

        if let sessionStart = policy.sessionStartedAt {
            try await doomed.append(contentsOf: idsCaptured(before: sessionStart))
        }
        if let maxAge = policy.maxAge {
            try await doomed.append(contentsOf: idsCaptured(before: now.addingTimeInterval(-maxAge)))
        }

        let unique = Array(Set(doomed))
        if !unique.isEmpty {
            let timeReport = try await delete(ids: unique)
            report.deletedCount += timeReport.deletedCount
            report.freedBytes += timeReport.freedBytes
        }

        if let cap = policy.sizeCapBytes {
            let lru = try await evictLeastRecentlyUsed(downTo: cap)
            report.deletedCount += lru.deletedCount
            report.freedBytes += lru.freedBytes
        }
        return report
    }

    /// Recreates the index from sidecars + files. Missing files are skipped.
    @discardableResult
    public func rebuild() async throws -> Int {
        let urls = try FileManager.default.contentsOfDirectory(
            at: layout.sidecars,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM capture_records")
            try db.execute(sql: "DELETE FROM capture_fts")
        }

        var inserted = 0
        for url in urls {
            guard let record = try? HistorySidecar.read(from: url) else { continue }
            let file = fileURL(for: record)
            guard FileManager.default.fileExists(atPath: file.path) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            try await insert(record)
            inserted += 1
        }
        logger.info("Rebuilt history index with \(inserted, privacy: .public) records")
        return inserted
    }

    // MARK: - Private

    private func insert(_ record: HistoryRecord) async throws {
        do {
            try await dbPool.write { db in
                try record.insert(db)
            }
        } catch {
            throw HistoryError.database(error.localizedDescription)
        }
    }

    private func idsCaptured(before cutoff: Date) async throws -> [UUID] {
        try await dbPool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM capture_records WHERE captured_at < ?",
                arguments: [cutoff]
            )
            return ids.compactMap(UUID.init(uuidString:))
        }
    }

    private func evictLeastRecentlyUsed(downTo cap: Int64) async throws -> EvictionReport {
        var report = EvictionReport()
        while true {
            let usage = try await storageUsage()
            guard usage.byteCount > cap, usage.itemCount > 0 else { break }
            let oldest: String? = try await dbPool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM capture_records ORDER BY last_accessed_at ASC, captured_at ASC LIMIT 1"
                )
            }
            guard let oldest, let id = UUID(uuidString: oldest) else { break }
            let piece = try await deleteOne(id: id)
            report.deletedCount += piece.deletedCount
            report.freedBytes += piece.freedBytes
        }
        return report
    }

    private func deleteOne(id: UUID) async throws -> EvictionReport {
        guard let record = try await record(id: id) else { return .empty }

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM capture_records WHERE id = ?", arguments: [id.uuidString])
            // The index is a separate table with no foreign key, so it has to be told.
            try db.execute(sql: "DELETE FROM capture_fts WHERE id = ?", arguments: [id.uuidString])
        }
        try? FileManager.default.removeItem(at: layout.sidecarURL(id: id))

        let remaining = try await dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM capture_records WHERE content_hash = ?",
                arguments: [record.contentHash]
            ) ?? 0
        }

        var freed: Int64 = 0
        if remaining == 0 {
            let file = fileURL(for: record)
            let thumb = thumbnailFileURL(for: record)
            freed = record.byteSize
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: thumb)
        }

        logger.info("Deleted \(record.originalFilename, privacy: .public)")
        return EvictionReport(deletedCount: 1, freedBytes: freed)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
