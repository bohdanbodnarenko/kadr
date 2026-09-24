import AppKit
import CaptureCore
import Foundation
import MediaExport
import os
import SettingsKit
import Shared

@MainActor
extension QuickAccessManager {
    func compress(_ item: QuickAccessItem) {
        guard !item.isVideo else { return }
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        let format = settings.compressionFormat
        // Scratch: the helper writes here and the result is copied beside the original,
        // so nothing needs this once the launch is over (docs/17 §5 theme 7).
        let destination = (try? LaunchScratch.current.url(named: "compressed.\(format.fileExtension)"))
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-compressed-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)

        Task { [weak self] in
            guard let self else { return }
            setActivity(.compressing, on: item)
            defer { vision.disconnect() }
            defer { setActivity(nil, on: item) }
            do {
                let response = try await vision.compressImage(CompressRequest(
                    sourcePath: url.path,
                    destinationPath: destination.path,
                    targetBytes: settings.compressionTargetBytes,
                    format: format.rawValue
                ))
                guard response.isWorthwhile else {
                    // A screenshot of flat colour re-encodes larger than its PNG. Saying
                    // so beats putting a bigger file on the clipboard and calling it
                    // compressed.
                    try? FileManager.default.removeItem(at: destination)
                    presentFeedback(FeedbackStatus(
                        kind: .warning,
                        message: String(localized: "Already as small as it gets")
                    ))
                    return
                }
                let saved = persistCompressedFile(at: URL(fileURLWithPath: response.path), source: url, format: format)
                copyFile(at: saved)
                showCompressionResult(response, for: item)
                presentCompressedCard(at: saved, after: item, response: response)
            } catch {
                logger.error("Compression failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: destination)
                showCompressionResult(nil, for: item)
                presentFeedback(.failure(
                    String(localized: "Compression failed"),
                    retryTitle: String(localized: "Retry"),
                    retry: { [weak self] in self?.compress(item) }
                ))
            }
        }
    }

    /// Puts the savings on the card, or says there were none.
    private func showCompressionResult(_ response: CompressResponse?, for item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].compressionSavings = response.map(\.savingsFraction)
        items[index].wasCompressed = true
    }

    func setActivity(_ activity: CardActivity?, on item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].activity = activity
        if activity != nil {
            presentFeedback(FeedbackStatus(kind: .progress, message: String(localized: "Compressing…")))
        }
    }

    func persistCompressedFile(at source: URL, source original: URL, format: CompressedImageFormat) -> URL {
        let stem = original.deletingPathExtension().lastPathComponent + "-compressed"
        let directory = StagingArea.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)-\(index).\(format.fileExtension)")
            index += 1
        }
        try? FileManager.default.copyItem(at: source, to: destination)
        return FileManager.default.fileExists(atPath: destination.path) ? destination : source
    }

    func presentCompressedCard(at url: URL, after source: QuickAccessItem, response: CompressResponse) {
        var card = QuickAccessItem(
            fileURL: url,
            isStaged: true,
            pixelSize: source.pixelSize,
            scale: source.scale,
            capturedAt: Date(),
            displayID: source.displayID
        )
        card.wasCompressed = true
        card.compressionSavings = response.savingsFraction
        card.displayName = url.lastPathComponent
        present(card)
        ingest(card)
        let percent = Int((response.savingsFraction * 100).rounded())
        let size = ByteCountFormatter.string(fromByteCount: Int64(response.compressedBytes), countStyle: .file)
        presentFeedback(.done("\(formatTitle(response)) · \(percent)% smaller · \(size) — copied"))
    }

    private func formatTitle(_ response: CompressResponse) -> String {
        let ext = URL(fileURLWithPath: response.path).pathExtension.uppercased()
        return ext.isEmpty ? "Compressed" : ext
    }

    // Recognises the text in a card's capture and copies it (docs/03 §1.7, §2).
    //
    // Acting on a staged capture finalises it first, exactly like Copy or Pin: the user
    // has done something with this screenshot, so it stops being disposable.
}
