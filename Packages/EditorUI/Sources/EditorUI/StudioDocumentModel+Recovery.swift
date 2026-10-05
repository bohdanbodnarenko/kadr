import Foundation

@MainActor
public extension StudioDocumentModel {
    /// Runs a failed operation again, from its failure banner (docs/18 STU-2).
    func retry(_ operation: StudioFailurePresentation.Operation) async {
        switch operation {
        case let .export(destination):
            await export(to: destination)
        case .copyEdited:
            await copyEditedToClipboard()
        case .shareEdited:
            await shareEdited()
        case let .exportAudio(destination, format):
            await exportEditedAudio(to: destination, format: format)
        case .installSpeechModel:
            installSpeechModel()
        case .transcribe:
            await tidySpeech()
        }
    }

    /// Deletes staged renders older than `maximumAge`, for every session. Called at launch,
    /// so a copy survives its window long enough to be pasted (docs/18 STU-1).
    @discardableResult
    nonisolated static func sweepStagedRenders(
        olderThan maximumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        root: URL = stagingRoot
    ) -> Int {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maximumAge else { continue }
            if (try? manager.removeItem(at: folder)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
