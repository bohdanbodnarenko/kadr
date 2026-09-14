import HistoryKit
import SwiftUI

extension HistoryView {
    var currentFilter: HistoryFilter {
        HistoryFilter(kind: kindFilter, capturedAfter: dateFilter.capturedAfter)
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

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                revealSelected()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(selection.selected.count != 1)

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
