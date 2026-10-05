import Foundation
import StudioRender

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
        case .transcribeOnly:
            await transcribeOnly()
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

extension StudioDocumentModel {
    /// What an export of `snapshot` should weigh, or nil when the settings cannot say.
    func estimatedExportBytes(for snapshot: StudioExportSnapshot) -> Int? {
        let size = StudioRenderPlan.outputSize(
            edit: snapshot.edit,
            sourceSize: manifest.pixelSize,
            maxLongestEdge: snapshot.settings.maxLongestEdge
        )
        return snapshot.settings.estimatedBytes(
            outputSize: size,
            duration: snapshot.edit.duration,
            manifestFrameRate: manifest.frameRate
        )
    }
}

extension StudioDocumentModel {
    /// The guard `tidySpeech` applies before it rebuilds the timeline.
    ///
    /// Its own method so a test can reach it: the rest of `tidySpeech` needs a microphone,
    /// a permission grant and a speech model, and the refusal needs none of those — which
    /// is exactly the split that let the bug through in the first place.
    func refuseTidyIfEditedForTesting() {
        guard edit.clips.isEdited(ofRecordingLasting: manifest.duration) else { return }
        failure = .tidyRefused()
    }

    nonisolated static let tidyRefusal = "Speech tidying works on a recording you have not cut or re-timed yet. "
        + "Undo your clip edits first, or trim the pauses by hand."

    static let inspectorPresentedKey = "studio.inspector.presented"

    static var rememberedInspectorPresented: Bool {
        UserDefaults.standard.object(forKey: inspectorPresentedKey) as? Bool ?? true
    }

    /// Roughly how long an export has left, or nil until there is enough to go on.
    ///
    /// Linear in progress: a render's frames cost about the same each, so the elapsed
    /// time per percent is a fair guess at the rest. Nothing is said for the first 5%,
    /// where the reader and encoder are still warming up.
    nonisolated static func exportTimeLeft(progress: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard progress >= 0.05, progress < 1, elapsed > 0 else { return nil }
        return elapsed * (1 - progress) / progress
    }

    /// "42% · about 3 min left", for the export control.
    func exportProgressLabel(now: Date = Date()) -> String? {
        guard let progress = exportProgress else { return nil }
        let percent = "\(Self.exportPercent(progress))%"
        guard let started = exportStartedAt,
              let left = Self.exportTimeLeft(progress: progress, elapsed: now.timeIntervalSince(started))
        else { return percent }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = left >= 60 ? [.hour, .minute] : [.second]
        formatter.maximumUnitCount = 1
        guard let text = formatter.string(from: max(left, 1)) else { return percent }
        return "\(percent) · about \(text) left"
    }
}
