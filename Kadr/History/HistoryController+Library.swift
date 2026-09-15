import AppKit
import HistoryKit
import MediaExport
import Shared

extension HistoryController {
    func copy(ids: [UUID]) {
        let selected = ids.compactMap(record(id:))
        guard let first = selected.first, let url = fileURL(for: first) else { return }
        markAccessed(first)
        if selected.count == 1, first.kind != .video, let data = try? Data(contentsOf: url) {
            let format = ImageFormat(fileExtension: url.pathExtension) ?? .png
            ClipboardWriter.shared.write(data: data, format: format, fileURL: url)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = selected.compactMap { record -> URL? in
            guard let source = fileURL(for: record) else { return nil }
            markAccessed(record)
            return hardLink(for: record, at: source)
        }
        pasteboard.writeObjects(urls as [NSURL])
    }

    func reveal(ids: [UUID]) {
        let urls = ids.compactMap { id -> URL? in
            guard let record = record(id: id), let url = fileURL(for: record) else { return nil }
            markAccessed(record)
            return url
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func export(ids: [UUID], to directory: URL) {
        for id in ids {
            guard let record = record(id: id), let source = fileURL(for: record) else { continue }
            markAccessed(record)
            var destination = directory.appendingPathComponent(record.originalFilename)
            var index = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                let stem = (record.originalFilename as NSString).deletingPathExtension
                let ext = (record.originalFilename as NSString).pathExtension
                destination = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
                index += 1
            }
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func hardLink(for record: HistoryRecord, at source: URL) -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(record.originalFilename)
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.linkItem(at: source, to: temp)
        return FileManager.default.fileExists(atPath: temp.path) ? temp : source
    }
}
