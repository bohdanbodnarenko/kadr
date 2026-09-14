import Foundation
import StudioSession

/// Saved looks: apply one, remember which one is on, restore a default on a fresh recording
/// (docs/09 U3.5).
public extension StudioDocumentModel {
    /// The look last chosen from the bar, so "edited" means it has drifted from that
    /// choice rather than from nothing.
    var appliedPresetID: UUID? {
        get { storedAppliedPresetID }
        set { storedAppliedPresetID = newValue }
    }

    func applyPreset(_ preset: StudioPreset) {
        apply(preset)
        appliedPresetID = preset.id
    }

    func saveCurrentPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = StudioPreset(name: trimmed, capturing: edit)
        presetStore.add(preset)
        appliedPresetID = preset.id
    }

    func deletePreset(id: UUID) {
        presetStore.remove(id: id)
        if appliedPresetID == id {
            appliedPresetID = nil
        }
    }

    func setDefaultPreset(id: UUID?) {
        presetStore.setDefault(id: id)
    }

    /// A brand-new recording picks up a studio look and, when the clicks support it,
    /// the same automatic zooms Screendrop opens with.
    ///
    /// A draft or a committed edit is already a decision, so it is left alone. The
    /// Presenter card is the fallback when nobody has chosen a default — opening onto a
    /// raw SCK movie is what made the studio feel unfinished.
    func applyDefaultPresetIfFresh() {
        guard document.edit(StudioEdit.self) == nil else { return }
        guard !canUndo else { return }
        let preset = presetStore.defaultPreset() ?? StudioPreset.presenter
        var next = resolvingBakedCursor(preset.applied(to: edit))
        let planned = ZoomCuePlanner().cues(
            for: telemetry.clicks,
            in: manifest.pixelSize,
            duration: manifest.duration
        )
        let rebased = next.clips.rebasing(planned)
        if !rebased.isEmpty {
            next.zooms = rebased
        }
        guard next != edit else { return }
        adoptEditWithoutUndo(next)
        appliedPresetID = preset.id
    }

    var isAppliedPresetEdited: Bool {
        guard var applied = allPresets.first(where: { $0.id == appliedPresetID }) else {
            return false
        }
        // A baked pointer cannot follow the look's reconstructed-cursor flag, and that
        // refusal is not a user edit of the preset.
        if manifest.hasBakedCursor {
            applied.showsCursor = false
        }
        return !applied.matches(edit)
    }

    var appliedPresetName: String? {
        allPresets.first { $0.id == appliedPresetID }?.name
    }

    var allPresets: [StudioPreset] {
        presetStore.all()
    }

    var userPresets: [StudioPreset] {
        presetStore.load()
    }

    var defaultPresetID: UUID? {
        presetStore.defaultID()
    }
}
