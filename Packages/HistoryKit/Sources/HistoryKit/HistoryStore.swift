import CoreGraphics
import Foundation
import GRDB
import MediaExport
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

    /// How much memory the database connections may hold.
    public struct Tuning: Sendable, Equatable {
        /// Concurrent read connections.
        public var maximumReaderCount: Int
        /// SQLite's page cache per connection, in KiB.
        public var pageCacheKiB: Int

        public init(maximumReaderCount: Int, pageCacheKiB: Int) {
            self.maximumReaderCount = max(1, maximumReaderCount)
            self.pageCacheKiB = max(1, pageCacheKiB)
        }

        /// For the resident agent (PRD §8): one reader and a 512 KiB page cache per
        /// connection, instead of GRDB's five readers at SQLite's 2 MB each.
        public static let agent = Tuning(maximumReaderCount: 1, pageCacheKiB: 512)
    }

    /// Opens (or creates) the library at `root`. Cheap: a few SQLite pages, no images —
    /// but still file I/O and migrations, so call it off the main thread.
    public nonisolated static func open(root: URL, tuning: Tuning = .agent) throws -> HistoryStore {
        let layout = HistoryLayout(root: root)
        try layout.prepare()
        let pool = try HistoryDatabase.makePool(at: layout.databaseURL, tuning: tuning)
        do {
            try HistoryDatabase.migrator.migrate(pool)
        } catch {
            throw HistoryError.database(error.localizedDescription)
        }
        return HistoryStore(layout: layout, dbPool: pool)
    }

    /// Application Support library used by the agent.
    public nonisolated static func openApplicationSupport(tuning: Tuning = .agent) throws -> HistoryStore {
        try open(root: HistoryLayout.applicationSupport().root, tuning: tuning)
    }

    /// Gives back what SQLite cached while the library was being read.
    ///
    /// For after one-off work — the launch-time retention pass, a closed History window —
    /// so the agent does not keep pages around that it will not read again soon.
    public func releaseMemory() {
        dbPool.releaseMemory()
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
        // A poster rendered for this ingest is scratch: once the library has its own copy
        // there is nothing left to keep, and nothing else will come back for it.
        defer {
            if draft.thumbnailSourceIsTemporary, let poster = draft.thumbnailSourceURL {
                try? FileManager.default.removeItem(at: poster)
            }
        }
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
            originalFilename: draft.originalFilename,
            originalPath: draft.originalURL?.standardizedFileURL.path
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

    /// Updates the name shown in History. The capture file itself is content-addressed
    /// and is not renamed.
    ///
    /// The name is sanitised: it becomes a real filename the moment an item is exported,
    /// dragged or copied out, and a `/` in it escaped the export folder (docs/17 T-OUT-10).
    public func rename(id: UUID, to filename: String) async throws {
        let trimmed = Self.sanitisedFilename(filename)
        guard !trimmed.isEmpty, let existing = try await record(id: id) else { return }
        var copy = existing
        copy.originalFilename = trimmed
        let persisted = copy
        try HistorySidecar.write(persisted, to: layout.sidecarURL(id: id))
        try await write { db in
            try persisted.update(db)
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
            // The id tiebreak matches keyset paging, so the first page and the ones after
            // it agree on where equal keys fall (docs/18 OUT-9).
            let ordered = HistoryRecord.order(Self.order(for: filter.sort), Self.tiebreak(for: filter.sort))
            let request = Self.apply(filter, to: ordered)
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

    static func order(for sort: HistorySort) -> SQLOrderingTerm {
        switch sort {
        case .newest: Column("captured_at").desc
        case .oldest: Column("captured_at").asc
        case .largest: Column("byte_size").desc
        case .name: Column("original_filename").asc
        }
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

    /// What happens to bytes on disk when a record goes away.
    public enum FileDisposition: Sendable {
        /// Retention and privacy-correct eviction — bytes are destroyed.
        case permanent
        /// User-initiated delete — recoverable from the Trash (docs/14 UX-22).
        case trash
    }

    /// Deletes the records and, when nothing else shares the bytes, the files (docs/03 §5).
    public func delete(
        ids: [UUID],
        fileDisposition: FileDisposition = .permanent
    ) async throws -> EvictionReport {
        var report = EvictionReport()
        for id in ids {
            let piece = try await deleteOne(id: id, fileDisposition: fileDisposition)
            report.deletedCount += piece.deletedCount
            report.freedBytes += piece.freedBytes
        }
        return report
    }

    /// Deletes every record sharing a capture's bytes (docs/03 §5, docs/07 H5).
    ///
    /// By content hash, because that is what the library is keyed on: a capture the user
    /// deleted from the overlay must not survive as a content-addressed copy in App
    /// Support until retention expires. "Deleted" has to mean deleted.
    @discardableResult
    public func delete(contentHash: String) async throws -> EvictionReport {
        let ids: [UUID] = try await dbPool.read { db in
            let raw = try String.fetchAll(
                db,
                sql: "SELECT id FROM capture_records WHERE content_hash = ?",
                arguments: [contentHash]
            )
            return raw.compactMap(UUID.init(uuidString:))
        }
        guard !ids.isEmpty else { return .empty }
        return try await delete(ids: ids)
    }

    /// A display name made safe to use as a filename: no path separators or characters
    /// macOS refuses, no leading dot, and short enough for APFS.
    public nonisolated static func sanitisedFilename(_ name: String) -> String {
        FilenameTemplate.truncated(FilenameTemplate.sanitise(name))
    }

    /// The library's address for the file at `url`.
    ///
    /// Exposed because content addressing is the library's own scheme and a caller that
    /// is about to *destroy* the file needs the address while the bytes still exist —
    /// trashing first and hashing afterwards deletes nothing (docs/07 H5).
    public nonisolated static func contentHash(of url: URL) throws -> String {
        try HistoryContentAddress.hash(of: url)
    }

    /// Deletes whatever the library holds for the file at `url`.
    ///
    /// Only safe while the file is still readable; see `contentHash(of:)`.
    @discardableResult
    public func delete(fileMatching url: URL) async throws -> EvictionReport {
        try await delete(contentHash: HistoryStore.contentHash(of: url))
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
        let plan = try await retentionPlan(policy, now: now)
        guard !plan.ids.isEmpty else {
            return EvictionReport(stoppedAtEvictionLimit: plan.stoppedAtEvictionLimit)
        }
        var report = try await delete(ids: plan.ids)
        report.stoppedAtEvictionLimit = plan.stoppedAtEvictionLimit
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

    private func deleteOne(
        id: UUID,
        fileDisposition: FileDisposition = .permanent
    ) async throws -> EvictionReport {
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
            switch fileDisposition {
            case .permanent:
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: thumb)
            case .trash:
                // Under the name the user knows: Finder's Trash showed `3fa9c1….png`,
                // which nobody can recognise or Put Back to anything (docs/18 OUT-6).
                Self.trash(file, as: record.originalFilename, in: layout)
                try? FileManager.default.removeItem(at: thumb)
            }
        }

        logger.info("Deleted \(record.originalFilename, privacy: .public)")
        return EvictionReport(deletedCount: 1, freedBytes: freed)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

/// Split from the actor body for length; in this file because it reads `dbPool`.
public extension HistoryStore {
    /// What a retention pass would delete, without deleting anything (docs/17 T-OUT-4).
    ///
    /// The count and bytes a confirmation needs: "Permanently delete 312 captures
    /// (1.4 GB)?" has to be asked *before* the pass, and has to agree with it — so the pass
    /// runs this same plan.
    struct RetentionPlan: Sendable, Hashable {
        /// Older than the retention window, or from a previous session.
        public var expired: [UUID]
        /// Least recently used, evicted to bring the library under the cap.
        public var overCap: [UUID]
        /// Bytes those records account for.
        public var bytes: Int64
        public var stoppedAtEvictionLimit: Bool

        public var ids: [UUID] {
            expired + overCap
        }

        public var count: Int {
            expired.count + overCap.count
        }
    }

    func retentionPlan(_ policy: HistoryPolicy, now: Date = Date()) async throws -> RetentionPlan {
        var expired: Set<UUID> = []
        if let sessionStart = policy.sessionStartedAt {
            try await expired.formUnion(idsCaptured(before: sessionStart))
        }
        if let maxAge = policy.maxAge {
            try await expired.formUnion(idsCaptured(before: now.addingTimeInterval(-maxAge)))
        }

        // Oldest access first, which is the order the cap evicts in.
        let rows: [(id: UUID, bytes: Int64)] = try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, byte_size FROM capture_records ORDER BY last_accessed_at ASC, captured_at ASC"
            )
            .compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return (id, row["byte_size"] ?? 0)
            }
        }
        let expiredBytes = rows.filter { expired.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        var plan = RetentionPlan(
            expired: rows.map(\.id).filter { expired.contains($0) },
            overCap: [],
            bytes: expiredBytes,
            stoppedAtEvictionLimit: false
        )

        guard let cap = policy.sizeCapBytes else { return plan }
        var total = rows.reduce(Int64(0)) { $0 + $1.bytes } - expiredBytes
        for row in rows where total > cap {
            guard !expired.contains(row.id), !policy.protectedIDs.contains(row.id) else { continue }
            if let limit = policy.maxSizeCapEvictions, plan.overCap.count >= limit {
                plan.stoppedAtEvictionLimit = true
                break
            }
            plan.overCap.append(row.id)
            plan.bytes += row.bytes
            total -= row.bytes
        }
        return plan
    }
}
