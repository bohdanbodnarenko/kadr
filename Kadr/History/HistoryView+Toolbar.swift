import HistoryKit
import SwiftUI

extension HistoryView {
    var currentFilter: HistoryFilter {
        HistoryFilter(kind: kindFilter, capturedAfter: dateFilter.capturedAfter, sort: sort)
    }

    var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: {
                if !$0 {
                    renaming = nil
                }
            }
        )
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("All types") { kindFilter = nil }
                Divider()
                ForEach(HistoryItemKind.allCases, id: \.self) { kind in
                    Button(kind.title) { kindFilter = kind }
                }
            } label: {
                Label(kindFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
        }

        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(HistoryDateFilter.allCases) { filter in
                    Button(filter.title) { dateFilter = filter }
                }
            } label: {
                Label(dateFilter.title, systemImage: "calendar")
            }
            .menuStyle(.borderlessButton)
        }

        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(HistorySort.allCases, id: \.self) { option in
                    Button(option.title) { sort = option }
                }
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                revealSelected()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(selection.isEmpty)

            Menu {
                Button("Copy") { copySelected() }
                    .disabled(selection.isEmpty)
                Button("Annotate") {
                    selection.selected.compactMap { controller.record(id: $0) }.forEach {
                        controller.onAnnotate?($0)
                    }
                }
                .disabled(selection.selected.count != 1)
                Button("Pin") {
                    selection.selected.compactMap { controller.record(id: $0) }.forEach {
                        controller.onPin?($0)
                    }
                }
                .disabled(selection.selected.count != 1)
                Button("Export…") { exportSelected() }
                    .disabled(selection.isEmpty)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }

            Button(role: .destructive) {
                Task { await deleteSelected() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
    }

    var kindFilterLabel: String {
        kindFilter?.title ?? "All types"
    }
}
