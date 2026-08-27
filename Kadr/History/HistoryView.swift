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

            Button("Reveal in Finder") { revealSelected() }
                .disabled(selection.count != 1)
            Button("Delete", role: .destructive) { Task { await deleteSelected() } }
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var grid: some View {
        ScrollView {
            if controller.records.isEmpty, !controller.isLoading {
                ContentUnavailableView(
                    "No captures yet",
                    systemImage: "clock",
                    description: Text("Captures you take show up here, and in the menu bar strip.")
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

    private var footer: some View {
        HStack {
            storageMeter
            Spacer()
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
