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
        // Pickers inside the menus, so each shows a checkmark on what is chosen: a filter
        // you cannot see is one you forget you set (docs/18 OUT-7).
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Type", selection: $kindFilter) {
                    Text("All Types").tag(HistoryItemKind?.none)
                    Divider()
                    ForEach(HistoryItemKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(HistoryItemKind?.some(kind))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(
                    kindFilterLabel,
                    systemImage: kindFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .menuStyle(.borderlessButton)
        }

        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Date", selection: $dateFilter) {
                    ForEach(HistoryDateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(dateFilter.title, systemImage: dateFilter == .all ? "calendar" : "calendar.badge.clock")
            }
            .menuStyle(.borderlessButton)
        }

        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(HistorySort.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                revealSelected()
            } label: {
                Label("Show in Finder", systemImage: "folder")
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
                // It goes to the Trash, so it says so (docs/18 X-5 vocabulary).
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
    }

    var kindFilterLabel: String {
        kindFilter?.title ?? "All types"
    }
}
