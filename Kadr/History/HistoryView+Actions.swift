import AppKit
import HistoryKit
import SwiftUI

extension HistoryView {
    var storageMeter: some View {
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

    func revealSelected() {
        let ids = Array(selection.selected)
        if ids.count > 1 {
            controller.reveal(ids: ids)
            return
        }
        guard let id = selection.selected.first ?? selection.focused,
              let record = controller.record(id: id),
              let url = controller.fileURL(for: record)
        else { return }
        controller.markAccessed(record)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copySelected() {
        let ids = Array(selection.selected)
        guard !ids.isEmpty else { return }
        controller.copy(ids: ids)
    }

    func exportSelected() {
        let ids = Array(selection.selected)
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            controller.export(ids: ids, to: directory)
        }
    }
}
