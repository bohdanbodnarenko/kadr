import AppKit
import HistoryKit
import StudioSession
import SwiftUI
import UniformTypeIdentifiers

/// Grid browser: type/date filters, drag-out, batch select, reveal, delete, storage meter.
struct HistoryView: View {
    @Bindable var controller: HistoryController
    let open: (HistoryRecord) -> Void
    let openAsCard: (HistoryRecord) -> Void
    var preview: (HistoryRecord) -> Void = { _ in }

    @State var selection = HistorySelection()
    @State var kindFilter: HistoryItemKind?
    @State var dateFilter: HistoryDateFilter = .all
    @State var sort: HistorySort = .newest
    /// The search field's text (docs/03 §5 P3). Debounced before it reaches SQLite so a
    /// fast typist does not queue a query per keystroke.
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    /// Project titles from `.kadrrec` sidecars, keyed by the footage path.
    @State private var recordingTitles: [String: String] = [:]
    @State var renaming: HistoryRecord?
    @State private var renameText = ""
    @State private var pendingBatchDelete = false
    @FocusState private var gridFocused: Bool
    @State private var gridWidth: CGFloat = 560

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]

    private var batchDeleteMessage: String {
        KadrPlural.files(selection.selected.count) + ". You can recover them from the Trash."
    }

    var body: some View {
        historyChrome
    }

    private var historyChrome: some View {
        historyStack
            .alert("Rename", isPresented: renameAlertPresented) {
                TextField("Name", text: $renameText)
                Button("Rename") { applyRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                "Move to Trash?",
                isPresented: $pendingBatchDelete,
                titleVisibility: .visible
            ) {
                Button(batchDeleteButtonTitle, role: .destructive) {
                    Task { await performDelete(Array(selection.selected)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(batchDeleteMessage)
            }
    }

    private var historyStack: some View {
        historyLifecycleModifiers(
            historyFrame
                .searchable(text: $searchText, prompt: "Search captures")
                .toolbar { toolbarContent }
        )
    }

    private var historyFrame: some View {
        VStack(spacing: 0) {
            grid
            Divider()
            footer
        }
        .frame(minWidth: HistoryWindowGeometry.minimumWidth, minHeight: HistoryWindowGeometry.minimumHeight)
        .background(.background)
        .kadrLayoutDirection()
    }

    private var batchDeleteButtonTitle: String {
        "Move \(selection.selected.count) Items to Trash"
    }

    private func title(for record: HistoryRecord) -> String {
        if let url = controller.fileURL(for: record) {
            return recordingTitles[url.standardizedFileURL.path] ?? record.originalFilename
        }
        return record.originalFilename
    }

    private func canRename(_ record: HistoryRecord) -> Bool {
        controller.fileURL(for: record) != nil
    }

    private func refreshRecordingTitles() {
        guard let store = StudioSessionRecorder.store() else {
            recordingTitles = [:]
            return
        }
        let urls = controller.records.compactMap { controller.fileURL(for: $0) }
        recordingTitles = store.displayNames(forFootageAt: urls)
    }

    private func applyRename() {
        defer { renaming = nil }
        guard let record = renaming else { return }
        let filename = Self.libraryFilename(displayName: renameText, current: record.originalFilename)
        if let session = studioSession(for: record) {
            try? session.setDisplayName(renameText)
        }
        Task { await controller.rename(record, to: filename) }
        refreshRecordingTitles()
    }

    private func studioSession(for record: HistoryRecord) -> RecordingSession? {
        guard let url = controller.fileURL(for: record) else { return nil }
        return StudioSessionRecorder.session(forRecordingAt: url)
    }

    /// Keeps the capture's extension so a drag-out still writes a movie, not a nameless file.
    static func libraryFilename(displayName: String, current: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return current }
        let ext = (current as NSString).pathExtension
        guard !ext.isEmpty else { return trimmed }
        if (trimmed as NSString).pathExtension.lowercased() == ext.lowercased() {
            return trimmed
        }
        return "\(trimmed).\(ext)"
    }

    /// Waits for the typing to settle, then searches.
    ///
    /// 250 ms: long enough that a word is one query rather than five, short enough that
    /// the grid feels like it is following along.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await controller.search(text, filter: currentFilter)
        }
    }

    private var grid: some View {
        ZStack {
            if controller.records.isEmpty, controller.isLoading {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if controller.records.isEmpty, !controller.isLoading {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: controller.isSearching ? "magnifyingglass" : "clock",
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(controller.records) { record in
                                HistoryCell(
                                    record: record,
                                    title: title(for: record),
                                    cachedImage: controller.cachedThumbnail(for: record, maxPixelSize: 280),
                                    loadImage: { await controller.loadThumbnail(for: record, maxPixelSize: 280) },
                                    isSelected: selection.contains(record.id),
                                    isFocused: selection.isFocused(record.id)
                                )
                                // A promise, not a URL: library files are content-addressed, so
                                // dragging one out as a URL hands the receiver a file named after
                                // its hash. The promise carries the name the capture was given
                                // (docs/03 §6, docs/09 U0.1).
                                .overlay(
                                    FilePromiseDragView(
                                        payload: {
                                            FilePromisePayload(
                                                suggestedName: record.originalFilename,
                                                contentType: UTType(filenameExtension:
                                                    (record.originalFilename as NSString).pathExtension) ?? .png,
                                                resolve: {
                                                    controller.markAccessed(record)
                                                    return controller.fileURL(for: record)
                                                },
                                                stableFileURL: controller.fileURL(for: record)
                                            )
                                        },
                                        dragImage: {
                                            controller.thumbnail(for: record, maxPixelSize: 160)
                                                .map { NSImage(cgImage: $0, size: .zero) }
                                        },
                                        onTap: { handleTap(record.id) },
                                        onDoubleTap: { open(record) }
                                    )
                                )
                                .contextMenu { cellMenu(record) }
                                .onAppear {
                                    if record.id == controller.records.last?.id {
                                        Task { await controller.loadMore() }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    private func handleTap(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        selection.click(
            id,
            in: controller.records,
            command: flags.contains(.command),
            shift: flags.contains(.shift)
        )
        gridFocused = true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command), press.characters == "a" {
            selection.selectAll(in: controller.records)
            return .handled
        }

        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow:
            selection.moveFocus(.up, in: controller.records, extending: extending, windowWidth: gridWidth)
            return .handled
        case .downArrow:
            selection.moveFocus(.down, in: controller.records, extending: extending, windowWidth: gridWidth)
            return .handled
        case .leftArrow:
            selection.moveFocus(.left, in: controller.records, extending: extending, windowWidth: gridWidth)
            return .handled
        case .rightArrow:
            selection.moveFocus(.right, in: controller.records, extending: extending, windowWidth: gridWidth)
            return .handled
        case .space:
            if let id = selection.focused ?? selection.anchor, let record = controller.record(id: id) {
                preview(record)
            }
            return .handled
        case .return:
            if let id = selection.focused ?? selection.anchor, let record = controller.record(id: id) {
                open(record)
            }
            return .handled
        default:
            return .ignored
        }
    }

    @ViewBuilder
    private func cellMenu(_ record: HistoryRecord) -> some View {
        if record.kind == .video {
            Button("Open in Studio") { open(record) }
            if canRename(record) {
                Button("Rename") {
                    renameText = title(for: record)
                    renaming = record
                }
            }
        }
        Button("Open in Overlay") { openAsCard(record) }
            .keyboardShortcut(.return, modifiers: [.option])
        if record.kind != .video {
            Button("Annotate") { controller.onAnnotate?(record) }
            Button("Pin") { controller.onPin?(record) }
        }
        Button("Copy") {
            controller.copy(ids: [record.id])
        }
        Button("Copy Text") { controller.onCopyText?(record) }
        Button("Reveal in Finder") {
            selection.selected = [record.id]
            selection.anchor = record.id
            selection.focused = record.id
            revealSelected()
        }
        if let url = controller.fileURL(for: record) {
            ShareLink(item: url) {
                Text("Share…")
            }
            .accessibilityLabel("Share \(record.originalFilename)")
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await performDelete([record.id]) }
        }
    }

    private var emptyTitle: String {
        controller.isSearching ? "No matches" : "No captures yet"
    }

    /// Says *why* there is nothing, which for a search over a half-built index is the
    /// difference between "no results" and "not read yet" (docs/03 §5 P3).
    private var emptyDescription: String {
        guard controller.isSearching else {
            return "Captures you take show up here, and in the menu bar strip."
        }
        if !controller.indexing.isAllowed {
            return "Search reads the text in your captures. Turn it on in Settings → History, "
                + "and plug in — Kadr only reads them on mains power."
        }
        if controller.indexing.isRunning {
            return "Kadr is still reading your captures. Try again in a moment."
        }
        return "No capture contains that text, and no window or app name matches it."
    }

    private var footer: some View {
        HStack(spacing: 12) {
            storageMeter
            Spacer()
            if controller.isPaging {
                ProgressView()
                    .controlSize(.small)
                Text("Loading more…")
                    .foregroundStyle(.secondary)
            }
            if let error = controller.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Retry") {
                    Task {
                        if controller.records.isEmpty {
                            await controller.reload(filter: currentFilter)
                        } else {
                            await controller.loadMore()
                        }
                    }
                }
            }
            if controller.indexing.isRunning {
                Label("Indexing…", systemImage: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            if !selection.isEmpty {
                Text(KadrPlural.files(selection.selected.count) + " selected")
                    .foregroundStyle(.secondary)
            }
            Text(KadrPlural.captures(controller.usage.itemCount))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    func deleteSelected() async {
        let ids = Array(selection.selected)
        guard !ids.isEmpty else { return }
        if ids.count > 1 {
            pendingBatchDelete = true
            return
        }
        await performDelete(ids)
    }

    private func performDelete(_ ids: [UUID]) async {
        let removed = Set(ids)
        await controller.moveToTrash(ids: ids)
        selection.focusAfterDeletion(removed: removed, in: controller.records)
    }

    private func applyFilters() async {
        selection.clear()
        await controller.reload(filter: currentFilter)
    }

    private func historyLifecycleModifiers(_ content: some View) -> some View {
        content
            .onDeleteCommand { Task { await deleteSelected() } }
            .onCopyCommand {
                copySelected()
                return []
            }
            .focusable()
            .focused($gridFocused)
            .onKeyPress { handleKey($0) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .task { await controller.reload(filter: currentFilter) }
            .onChange(of: kindFilter) { _, _ in Task { await applyFilters() } }
            .onChange(of: dateFilter) { _, _ in Task { await applyFilters() } }
            .onChange(of: sort) { _, _ in Task { await applyFilters() } }
            .onChange(of: searchText) { _, text in scheduleSearch(text) }
            .onChange(of: controller.records) { _, _ in refreshRecordingTitles() }
            .onAppear {
                refreshRecordingTitles()
                gridFocused = true
            }
            .onDisappear { searchTask?.cancel() }
    }
}
