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
            ClipboardWriter.shared.write(data: data, format: format, fileURL: namedURL(for: first) ?? url)
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

    /// Copies items out under their names, off the main thread, and says if any failed
    /// (docs/17 T-OUT-13). It used to copy gigabytes synchronously and drop every error.
    func export(ids: [UUID], to directory: URL) {
        let jobs: [(source: URL, name: String)] = ids.compactMap { id in
            guard let record = record(id: id), let source = fileURL(for: record) else { return nil }
            markAccessed(record)
            let name = HistoryStore.sanitisedFilename(record.originalFilename)
            return (source, name.isEmpty ? source.lastPathComponent : name)
        }
        guard !jobs.isEmpty else { return }
        let sources = jobs.map(\.source)
        let names = jobs.map(\.name)
        Task {
            let failed = await Task.detached(priority: .userInitiated) {
                zip(sources, names).reduce(0) { failures, job in
                    (try? StagingArea.copy(job.0, named: job.1, into: directory)) == nil ? failures + 1 : failures
                }
            }.value
            guard failed > 0 else { return }
            FailurePresenter.present(.failure(failed == 1
                    ? String(localized: "Couldn't export 1 capture to \(directory.lastPathComponent)")
                    : String(localized: "Couldn't export \(failed) captures to \(directory.lastPathComponent)")))
        }
    }

    /// The library file under the name the user knows it by, for anything that hands it
    /// to another app (docs/17 T-OUT-10). Falls back to the hash-named file only if the
    /// scratch folder cannot be written.
    func namedURL(for record: HistoryRecord) -> URL? {
        guard let source = fileURL(for: record) else { return nil }
        return hardLink(for: record, at: source)
    }

    private func hardLink(for record: HistoryRecord, at source: URL) -> URL {
        let name = HistoryStore.sanitisedFilename(record.originalFilename)
        guard !name.isEmpty else { return source }
        return (try? LaunchScratch.current.link(source, named: name)) ?? source
    }
}
