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
    /// True while the next page is being fetched; the grid stays visible (docs/14 UX-23).
    private(set) var isPaging = false
    /// The last load or page failure, for inline Retry (docs/14 UX-23).
    private(set) var loadError: String?

    let cache = ThumbnailCache()
    private(set) var store: HistoryStore?
    private let settings: AppSettings
    private let launchedAt = Date()
    /// The retention setting as this launch found it. "This session only" clears what
    /// earlier launches kept only if it was already chosen when Kadr started — choosing it
    /// now takes effect at the next launch, as the pane says (docs/17 T-OUT-4).
    private let retentionAtLaunch: HistoryRetention
    /// Warned once per launch that the size cap stopped short (docs/17 T-OUT-8).
    private var hasWarnedAboutCap = false
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
    /// History deletes inside their Undo window (docs/17 T-OUT-7).
    @ObservationIgnored private var pendingTrash: [UUID: PendingTrash] = [:]

    private struct PendingTrash {
        let ids: Set<UUID>
        let commit: Task<Void, Never>
    }

    /// The open in flight, shared by everyone who asks before it finishes.
    @ObservationIgnored private var openTask: Task<HistoryStore, any Error>?

    /// What the History window's search field holds, and the indexer behind it
    /// (docs/03 §5 P3).
    private(set) var searchText = ""
    let indexing: HistoryIndexCoordinator
    var onPin: ((HistoryRecord) -> Void)?
    var onAnnotate: ((HistoryRecord) -> Void)?
    var onCopyText: ((HistoryRecord) -> Void)?

    static let menuStripCount = 8
    static let pageSize = 48

    init(settings: AppSettings, store: HistoryStore? = nil) {
        self.settings = settings
        self.store = store
        retentionAtLaunch = settings.historyRetention
        indexing = HistoryIndexCoordinator(settings: settings)
    }

    /// Whether a search is narrowing the grid right now.
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var policy: HistoryPolicy {
        policy(retention: settings.historyRetention, sizeCap: settings.historySizeCap)
    }

    /// The most captures an automatic size-cap pass removes before asking (docs/17 T-OUT-8).
    static let automaticEvictionLimit = 25

    /// The policy for a retention and cap, whether or not they are the current settings.
    ///
    /// Automatic passes — launch, ingest — protect what was just ingested and stop at
    /// `automaticEvictionLimit`; a pass the user confirmed in Settings has neither limit.
    func policy(
        retention: HistoryRetention,
        sizeCap: HistorySizeCap,
        protecting protectedIDs: Set<UUID> = [],
        confirmed: Bool = false
    ) -> HistoryPolicy {
        let sessionOnly = retention == .session && retentionAtLaunch == .session
        return HistoryPolicy(
            maxAge: retention.maxAge,
            sizeCapBytes: sizeCap.bytes,
            sessionStartedAt: sessionOnly ? launchedAt : nil,
            protectedIDs: protectedIDs,
            maxSizeCapEvictions: confirmed ? nil : Self.automaticEvictionLimit
        )
    }

    /// What a change to retention or the size cap would permanently delete, so the pane
    /// can ask first (docs/17 T-OUT-4).
    func retentionPreview(retention: HistoryRetention, sizeCap: HistorySizeCap) async -> HistoryStore.RetentionPlan? {
        await openIfNeeded()
        return try? await store?.retentionPlan(policy(retention: retention, sizeCap: sizeCap, confirmed: true))
    }

    /// Runs an automatic retention pass, and says so once if the cap had to stop short.
    private func applyAutomaticRetention(on store: HistoryStore, protecting ids: Set<UUID> = []) async {
        let automatic = policy(
            retention: settings.historyRetention,
            sizeCap: settings.historySizeCap,
            protecting: ids
        )
        guard let report = try? await store.applyRetention(automatic) else { return }
        if report.stoppedAtEvictionLimit, !hasWarnedAboutCap {
            hasWarnedAboutCap = true
            logger.info("History size cap stopped at the automatic eviction limit")
            FailurePresenter.present(FeedbackStatus(
                kind: .warning,
                message: String(localized: "History is over its size limit. Older captures were kept.")
            ))
        }
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

    func cachedThumbnail(
        for record: HistoryRecord,
        maxPixelSize: Int,
        scope: ThumbnailCache.Scope = .grid
    ) -> CGImage? {
        guard let store else { return nil }
        return cache.cached(for: store.thumbnailFileURL(for: record), maxPixelSize: maxPixelSize, scope: scope)
    }

    func loadThumbnail(
        for record: HistoryRecord,
        maxPixelSize: Int,
        scope: ThumbnailCache.Scope = .grid
    ) async -> CGImage? {
        guard let store else { return nil }
        let url = store.thumbnailFileURL(for: record)
        if let cached = cache.cached(for: url, maxPixelSize: maxPixelSize, scope: scope) {
            return cached
        }
        let image = await Task.detached { [store] in
            store.thumbnail(for: record, maxPixelSize: maxPixelSize)
        }.value
        if let image {
            cache.store(image, for: url, maxPixelSize: maxPixelSize, scope: scope)
        }
        return image
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
        loadError = nil
        defer {
            isLoading = false
            signposter.endInterval("historyColdOpen", interval)
        }

        do {
            // No retention pass here: this runs on every filter change and search
            // keystroke, and deleting permanently is not something a keystroke should do
            // (docs/17 T-OUT-4). Launch, ingest and a confirmed Settings change run it.
            if isSearching {
                records = try await visible(store.search(searchText, filter: filter))
                // A search returns its whole ranked result set, so there is no next page.
                hasMore = false
            } else {
                let page = try await store.loadPage(filter: filter, offset: 0, limit: Self.pageSize)
                records = visible(page)
                hasMore = page.count == Self.pageSize
            }
            usage = try await store.storageUsage()
            recent = try await visible(store.recent(limit: Self.menuStripCount))
        } catch {
            loadError = error.localizedDescription
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
        guard hasMore, let store, !isLoading, !isPaging else { return }
        isPaging = true
        defer { isPaging = false }
        pageOffset += Self.pageSize
        do {
            let page = try await store.loadPage(filter: filter, offset: pageOffset, limit: Self.pageSize)
            records.append(contentsOf: visible(page))
            hasMore = page.count == Self.pageSize
            loadError = nil
        } catch {
            pageOffset = max(0, pageOffset - Self.pageSize)
            loadError = error.localizedDescription
            logger.error("Could not page history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves library items to the Trash, with an Undo (docs/14 UX-22, docs/17 T-OUT-7).
    ///
    /// The rows go at once and the banner offers Undo; the delete itself waits out the
    /// Undo window. It has to: the library's files are named by hash, so once they are in
    /// the Trash, Finder's Put Back restores a `3fa9c1….png` and never the History row.
    /// Retention eviction stays permanent.
    func moveToTrash(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let batch = UUID()
        let hidden = Set(ids)
        pendingTrash[batch] = PendingTrash(ids: hidden, commit: Task { [weak self] in
            try? await Task.sleep(for: FeedbackStatus.undoWindow + .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.commitTrash(batch)
        })
        records.removeAll { hidden.contains($0.id) }
        recent.removeAll { hidden.contains($0.id) }
        let message = ids.count == 1
            ? String(localized: "Moved to Trash")
            : String(localized: "Moved \(ids.count) captures to Trash")
        FailurePresenter.present(.undoable(message) { [weak self] in
            Task { await self?.undoTrash(batch) }
        })
    }

    /// Puts a batch back, before its delete has run.
    func undoTrash(_ batch: UUID) async {
        guard let pending = pendingTrash.removeValue(forKey: batch) else { return }
        pending.commit.cancel()
        logger.info("Put \(pending.ids.count, privacy: .public) history item(s) back")
        await reload(filter: filter)
    }

    /// Deletes a batch whose Undo window has passed.
    func commitTrash(_ batch: UUID) async {
        guard let pending = pendingTrash.removeValue(forKey: batch) else { return }
        await openIfNeeded()
        guard let store else { return }
        do {
            _ = try await store.delete(ids: Array(pending.ids), fileDisposition: .trash)
            usage = try await store.storageUsage()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            logger.error("Could not delete history items: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records waiting out their Undo window are not shown, whatever a reload returns.
    private func visible(_ list: [HistoryRecord]) -> [HistoryRecord] {
        let hidden = pendingTrash.values.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
        return hidden.isEmpty ? list : list.filter { !hidden.contains($0.id) }
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
        guard store != nil, let hash = try? HistoryStore.contentHash(of: fileURL) else { return }
        deleteFromLibrary(contentHash: hash)
    }

    func deleteFromLibrary(contentHash hash: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let report = try? await store?.delete(contentHash: hash),
                  report.deletedCount > 0
            else {
                return
            }
            await reload(filter: currentFilter)
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

    /// Applies a Settings change. Retention runs without the automatic limits, because the
    /// pane has already shown the user what it deletes and they confirmed it.
    func applySettingsChange() {
        Task {
            await openIfNeeded()
            let confirmed = policy(
                retention: settings.historyRetention,
                sizeCap: settings.historySizeCap,
                confirmed: true
            )
            if await (try? store?.applyRetention(confirmed))?.deletedCount ?? 0 > 0 {
                await reload(filter: filter)
            }
            usage = await (try? store?.storageUsage()) ?? usage
            recent = await visible((try? store?.recent(limit: Self.menuStripCount)) ?? recent)

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

    /// Opens the library once, off the main thread, however many callers ask at once.
    ///
    /// `HistoryStore.open` creates directories, opens SQLite and runs migrations. It used
    /// to run synchronously on the main actor inside this `async` function, which made the
    /// first History action after launch a main-thread stall. Every caller already awaits
    /// this, so the open simply moves to a detached task; callers that arrive while it is
    /// running wait on the same task rather than opening a second pool.
    private func openIfNeeded() async {
        if store != nil {
            await drainPending()
            return
        }
        let opening = openTask ?? Task.detached(priority: .utility) {
            try HistoryStore.openApplicationSupport(tuning: .agent)
        }
        openTask = opening
        do {
            let opened = try await opening.value
            guard store == nil else {
                // Another caller finished the launch work while this one waited.
                await drainPending()
                return
            }
            store = opened
            await applyAutomaticRetention(on: opened)
            recent = try await visible(opened.recent(limit: Self.menuStripCount))
            usage = try await opened.storageUsage()
            await drainPending()
            // The launch pass read pages nothing will read again soon.
            await opened.releaseMemory()
        } catch {
            openTask = nil
            logger.error("Could not open history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func drainPending() async {
        guard let store, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        var ingested: Set<UUID> = []
        for draft in batch {
            do {
                try await ingested.insert(store.ingest(draft).id)
            } catch {
                logger.error("History ingest failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // What was just ingested is never what the cap evicts (docs/17 T-OUT-8).
        await applyAutomaticRetention(on: store, protecting: ingested)
        recent = await visible((try? store.recent(limit: Self.menuStripCount)) ?? recent)
        usage = await (try? store.storageUsage()) ?? usage

        // A capture just landed, so the agent is awake anyway: a good moment to read it
        // (docs/03 §5 — the index never wakes the agent by itself).
        startIndexingIfAllowed()
    }
}
