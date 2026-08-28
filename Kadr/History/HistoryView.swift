import AppKit
import HistoryKit
import SwiftUI

/// Date presets for the history browser (docs/03 §5).
enum HistoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case lastSevenDays
    case lastThirtyDays

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "Any time"
        case .today: "Today"
        case .lastSevenDays: "Last 7 days"
        case .lastThirtyDays: "Last 30 days"
        }
    }

    var capturedAfter: Date? {
        let calendar = Calendar.current
        switch self {
        case .all: return nil
        case .today: return calendar.startOfDay(for: Date())
        case .lastSevenDays: return calendar.date(byAdding: .day, value: -7, to: Date())
        case .lastThirtyDays: return calendar.date(byAdding: .day, value: -30, to: Date())
        }
    }
}

/// Grid browser: type/date filters, drag-out, batch select, reveal, delete, storage meter.
struct HistoryView: View {
    @Bindable var controller: HistoryController
    let reopen: (HistoryRecord) -> Void

    @State private var selection: Set<UUID> = []
    @State private var kindFilter: HistoryItemKind?
    @State private var dateFilter: HistoryDateFilter = .all
    /// The search field's text (docs/03 §5 P3). Debounced before it reaches SQLite so a
    /// fast typist does not queue a query per keystroke.
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(.background)
        .onDeleteCommand { Task { await deleteSelected() } }
        .task { await controller.reload(filter: currentFilter) }
        .onChange(of: kindFilter) { _, _ in Task { await applyFilters() } }
        .onChange(of: dateFilter) { _, _ in Task { await applyFilters() } }
        .onChange(of: searchText) { _, text in scheduleSearch(text) }
        .onDisappear { searchTask?.cancel() }
    }

    private var currentFilter: HistoryFilter {
        HistoryFilter(kind: kindFilter, capturedAfter: dateFilter.capturedAfter)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Type", selection: $kindFilter) {
                Text("All types").tag(nil as HistoryItemKind?)
                ForEach(HistoryItemKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind as HistoryItemKind?)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            Picker("Date", selection: $dateFilter) {
                ForEach(HistoryDateFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .frame(maxWidth: 160)

            Spacer()

            SearchField(text: $searchText)
                .frame(width: 200)

            Button("Reveal in Finder") { revealSelected() }
                .disabled(selection.count != 1)
            Button("Delete", role: .destructive) { Task { await deleteSelected() } }
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                            image: controller.thumbnail(for: record, maxPixelSize: 280),
                            isSelected: selection.contains(record.id)
                        )
                        .onTapGesture(count: 2) { reopen(record) }
                        .onTapGesture { toggleSelection(record.id) }
                        .onDrag {
                            controller.markAccessed(record)
                            guard let url = controller.fileURL(for: record) else {
                                return NSItemProvider()
                            }
                            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                        }
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

    @ViewBuilder
    private func cellMenu(_ record: HistoryRecord) -> some View {
        Button("Open in Overlay") { reopen(record) }
        Button("Reveal in Finder") {
            selection = [record.id]
            revealSelected()
        }
        if let url = controller.fileURL(for: record) {
            ShareLink(item: url) {
                Text("Share…")
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await controller.delete(ids: [record.id]) }
            selection.remove(record.id)
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
        HStack {
            storageMeter
            Spacer()
            if controller.indexing.isRunning {
                Label("Indexing…", systemImage: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .foregroundStyle(.secondary)
            }
            Text("\(controller.usage.itemCount) items")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var storageMeter: some View {
        let used = controller.usage.byteCount
        let cap = controller.policy.sizeCapBytes
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        return HStack(spacing: 8) {
            if let cap, cap > 0 {
                ProgressView(value: Double(used), total: Double(cap))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(usedText) of \(ByteCountFormatter.string(fromByteCount: cap, countStyle: .file))")
            } else {
                Text(usedText)
            }
        }
        .help("Space used by the History library")
    }

    private func toggleSelection(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else if NSEvent.modifierFlags.contains(.shift), let last = selection.first {
            selectRange(from: last, to: id)
        } else {
            selection = [id]
        }
    }

    private func selectRange(from: UUID, to: UUID) {
        let ids = controller.records.map(\.id)
        guard let start = ids.firstIndex(of: from), let end = ids.firstIndex(of: to) else {
            selection = [to]
            return
        }
        let range = start <= end ? start ... end : end ... start
        selection.formUnion(ids[range])
    }

    private func revealSelected() {
        guard let id = selection.first,
              let record = controller.record(id: id),
              let url = controller.fileURL(for: record)
        else { return }
        controller.markAccessed(record)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func deleteSelected() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        await controller.delete(ids: ids)
        selection.subtract(ids)
    }

    private func applyFilters() async {
        selection.removeAll()
        await controller.reload(filter: currentFilter)
    }
}

private struct HistoryCell: View {
    let record: HistoryRecord
    let image: CGImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
                if record.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                // A project looks like the capture it is built on, so it needs a badge to
                // say that opening it reopens an editing session (docs/06 M24).
                if record.kind == .project {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 3 : 1
                    )
            )

            Text(record.originalFilename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(record.width) × \(record.height)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.originalFilename)
        .accessibilityAddTraits(.isButton)
    }
}
