import Foundation
import GRDB

/// Keyset paging for the History window (docs/18 OUT-9).
///
/// `LIMIT … OFFSET` counts rows from the top on every page, so a capture ingested or
/// deleted while the window was open shifted every later page by one: the user saw a row
/// twice, or never. A page that starts *after the last row shown* cannot drift.
public extension HistoryStore {
    /// The page that follows `last` in `filter`'s order; the first page when `last` is nil.
    func loadPage(filter: HistoryFilter, after last: HistoryRecord?, limit: Int) async throws -> [HistoryRecord] {
        guard let last else {
            return try await loadPage(filter: filter, offset: 0, limit: limit)
        }
        let sort = filter.sort
        return try await read { db in
            let ordered = HistoryRecord.order(Self.order(for: sort), Self.tiebreak(for: sort))
            return try Self.apply(filter, to: ordered)
                .filter(Self.follows(last, in: sort))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Whether `record` belongs in a grid showing `filter`, for inserting a fresh capture
    /// into an open window without reloading it.
    nonisolated static func matches(_ record: HistoryRecord, filter: HistoryFilter) -> Bool {
        if let kind = filter.kind, record.kind != kind {
            return false
        }
        if let after = filter.capturedAfter, record.capturedAt < after {
            return false
        }
        if let before = filter.capturedBefore, record.capturedAt > before {
            return false
        }
        return true
    }

    /// The id breaks ties, in the sort's own direction, so rows with the same key still
    /// have one fixed order to page through.
    internal nonisolated static func tiebreak(for sort: HistorySort) -> SQLOrderingTerm {
        switch sort {
        case .newest, .largest: Column("id").desc
        case .oldest, .name: Column("id").asc
        }
    }

    /// Rows strictly after `last` in `sort`'s order.
    internal nonisolated static func follows(_ last: HistoryRecord, in sort: HistorySort) -> SQLExpression {
        let id = Column("id")
        let lastID = last.id.uuidString
        switch sort {
        case .newest:
            let key = Column("captured_at")
            return key < last.capturedAt || (key == last.capturedAt && id < lastID)
        case .oldest:
            let key = Column("captured_at")
            return key > last.capturedAt || (key == last.capturedAt && id > lastID)
        case .largest:
            let key = Column("byte_size")
            return key < last.byteSize || (key == last.byteSize && id < lastID)
        case .name:
            let key = Column("original_filename")
            return key > last.originalFilename || (key == last.originalFilename && id > lastID)
        }
    }
}
