import CoreGraphics
import Foundation
import HistoryKit
import os
import SettingsKit
import Shared

/// Main-actor façade over `HistoryStore` (docs/03 §5, docs/04 §1).
///
/// The actor does the I/O; this type holds the last-8 cache the status menu reads
/// synchronously and the paged list the History window observes. No timers — refresh
/// happens on ingest, on launch, and when the window asks.
@MainActor
@Observable
final class HistoryController {
    private(set) var recent: [HistoryRecord] = []
    private(set) var records: [HistoryRecord] = []
    private(set) var usage: HistoryStorageUsage = .zero
    private(set) var hasMore = false
    private(set) var isLoading = false

    let cache = ThumbnailCache()
    private(set) var store: HistoryStore?
    private let settings: AppSettings
    private let launchedAt = Date()
    private let logger = KadrLog.logger(.history)
    private let signposter = KadrLog.signposter(.history)
    private var window: HistoryWindowController?
    private var pageOffset = 0
    private var filter = HistoryFilter.all

    /// The filter the window is currently showing, for refreshes driven from elsewhere.
    var currentFilter: HistoryFilter {
        filter
    }

    private var pending: [HistoryIngest] = []

    /// What the History window's search field holds, and the indexer behind it
    /// (docs/03 §5 P3).
    private(set) var searchText = ""
    let indexing: HistoryIndexCoordinator

    static let menuStripCount = 8
    static let pageSize = 48

    init(settings: AppSettings, store: HistoryStore? = nil) {
        self.settings = settings
        self.store = store
        indexing = HistoryIndexCoordinator(settings: settings)
    }

    /// Whether a search is narrowing the grid right now.
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var policy: HistoryPolicy {
        HistoryPolicy(
            maxAge: settings.historyRetention.maxAge,
            sizeCapBytes: settings.historySizeCap.bytes,
            sessionStartedAt: settings.historyRetention == .session ? launchedAt : nil
        )
    }

    var hasItems: Bool {
        !recent.isEmpty || usage.itemCount > 0
    }

    /// Opens the library and applies retention once. Called after the status item is up
    /// so SQLite cannot eat into the launch budget (PRD §8).
    func start() {
        Task { await openIfNeeded() }
    }

    func ingest(_ draft: HistoryIngest) {
        pending.append(draft)
        Task { await drainPending() }
    }

    func mostRecent() async -> HistoryRecord? {
        if let first = recent.first {
            return first
        }
        await openIfNeeded()
        return try? await store?.recent(limit: 1).first
    }

    func record(id: UUID) -> HistoryRecord? {
        recent.first { $0.id == id } ?? records.first { $0.id == id }
    }

    func fileURL(for record: HistoryRecord) -> URL? {
        store?.fileURL(for: record)
    }

    func thumbnail(for record: HistoryRecord, maxPixelSize: Int, scope: ThumbnailCache.Scope = .grid) -> CGImage? {
        guard let store else { return nil }
        let url = store.thumbnailFileURL(for: record)
        return cache.thumbnail(for: url, maxPixelSize: maxPixelSize, scope: scope)
    }

    func purgeStripThumbnails() {
        cache.purgeStrip()
    }

    func showWindow(
        reopen: @escaping (HistoryRecord) -> Void,
        openStudio: @escaping (HistoryRecord) -> Void
    ) {
        if window == nil {
            window = HistoryWindowController(controller: self, reopen: reopen, openStudio: openStudio)
        }
        window?.show()
    }

    func reload(filter: HistoryFilter) async {
        self.filter = filter
        pageOffset = 0
        await openIfNeeded()
        guard let store else { return }

        let interval = signposter.beginInterval("historyColdOpen")
        isLoading = true
        defer {
            isLoading = false
            signposter.endInterval("historyColdOpen", interval)
        }

        do {
            try await store.applyRetention(policy)
            if isSearching {
                records = try await store.search(searchText, filter: filter)
                // A search returns its whole ranked result set, so there is no next page.
                hasMore = false
            } else {
                let page = try await store.loadPage(filter: filter, offset: 0, limit: Self.pageSize)
                records = page
                hasMore = page.count == Self.pageSize
            }
            usage = try await store.storageUsage()
            recent = try await store.recent(limit: Self.menuStripCount)
        } catch {
            logger.error("Could not load history: \(error.localizedDescription, privacy: .public)")
        }

        // Opening the window is a thing the user did, so it is a fair moment to read a
        // few more captures — never a timer (docs/03 §5).
        startIndexingIfAllowed()
    }

    /// Runs a search, or clears one. Reloading is what actually queries.
    func search(_ text: String, filter: HistoryFilter) async {
        searchText = text
        await reload(filter: filter)
    }

    /// Asks the helper to read a batch, if the user opted in and the machine can afford it.
    func startIndexingIfAllowed() {
        guard let store else { return }
        indexing.requestPass(store: store)
    }

    func loadMore() async {
        guard hasMore, let store, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        pageOffset += Self.pageSize
        do {
            let page = try await store.loadPage(filter: filter, offset: pageOffset, limit: Self.pageSize)
            records.append(contentsOf: page)
            hasMore = page.count == Self.pageSize
        } catch {
            logger.error("Could not page history: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(ids: [UUID]) async {
        await openIfNeeded()
        guard let store, !ids.isEmpty else { return }
        do {
            _ = try await store.delete(ids: ids)
            records.removeAll { ids.contains($0.id) }
            recent.removeAll { ids.contains($0.id) }
            usage = try await store.storageUsage()
        } catch {
            logger.error("Could not delete history items: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes whatever the library holds for a file the user deleted elsewhere.
    ///
    /// Hashes the file first, because the library stores captures content-addressed and
    /// the record's own path is not the path the caller has (docs/07 H5).
    /// Removes the library's copy of the capture at `fileURL`.
    ///
    /// The address is taken synchronously, before returning: callers delete the file
    /// immediately afterwards, and a hash taken later would be a hash of nothing — which
    /// is how a "deleted" capture stayed in the library (docs/07 H5).
    func deleteFromLibrary(matching fileURL: URL) {
        guard let store, let hash = try? HistoryStore.contentHash(of: fileURL) else { return }
        Task { [weak self] in
            guard let report = try? await store.delete(contentHash: hash),
                  report.deletedCount > 0
            else {
                return
            }
            // Re-query rather than filtering the cached page by hand: the deletion may
            // have taken several records, and the window is showing whatever filter the
            // user set.
            await self?.reload(filter: self?.currentFilter ?? .all)
        }
    }

    func markAccessed(_ record: HistoryRecord) {
        Task {
            try? await store?.markAccessed(id: record.id)
        }
    }

    /// Updates the library name so search and the grid agree with a project title.
    func rename(_ record: HistoryRecord, to filename: String) async {
        await openIfNeeded()
        try? await store?.rename(id: record.id, to: filename)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index].originalFilename = filename
        }
        if let index = recent.firstIndex(where: { $0.id == record.id }) {
            recent[index].originalFilename = filename
        }
    }

    func applySettingsChange() {
        Task {
            await openIfNeeded()
            _ = try? await store?.applyRetention(policy)
            usage = await (try? store?.storageUsage()) ?? usage
            recent = await (try? store?.recent(limit: Self.menuStripCount)) ?? recent

            // Opting out is not just "stop indexing": what was already read has to go, or
            // the search field would keep finding text from captures the user has since
            // decided should not be searchable (docs/03 §5).
            if settings.historyIndexesText {
                startIndexingIfAllowed()
            } else {
                indexing.cancel()
                try? await store?.clearIndex()
            }
        }
    }

    // MARK: - Private

    private func openIfNeeded() async {
        if store != nil {
            await drainPending()
            return
        }
        do {
            let opened = try HistoryStore.openApplicationSupport()
            store = opened
            _ = try await opened.applyRetention(policy)
            recent = try await opened.recent(limit: Self.menuStripCount)
            usage = try await opened.storageUsage()
            await drainPending()
        } catch {
            logger.error("Could not open history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func drainPending() async {
        guard let store, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        for draft in batch {
            do {
                _ = try await store.ingest(draft)
            } catch {
                logger.error("History ingest failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        _ = try? await store.applyRetention(policy)
        recent = await (try? store.recent(limit: Self.menuStripCount)) ?? recent
        usage = await (try? store.storageUsage()) ?? usage

        // A capture just landed, so the agent is awake anyway: a good moment to read it
        // (docs/03 §5 — the index never wakes the agent by itself).
        startIndexingIfAllowed()
    }
}
