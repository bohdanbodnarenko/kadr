import StudioSession
import SwiftUI

extension StudioInspector {
    var audioSection: some View {
        StudioInspectorSection(title: "Audio", key: "audio", startsOpen: false) {
            if let name = model.edit.soundtrackDisplayName ?? model.edit.soundtrackFileName {
                Text("Using \(name) instead of the recording's own audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Remove soundtrack") { model.removeSoundtrack() }
                    .controlSize(.small)
            } else {
                Text("The recording's own audio, cut and sped with the picture.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Mute", isOn: Binding(
                get: { model.edit.mutesAudio },
                set: { value in model.change { $0.mutesAudio = value } }
            ))
            Toggle("Mix to mono", isOn: Binding(
                get: { model.edit.mixesToMono },
                set: { value in model.change { $0.mixesToMono = value } }
            ))
            .disabled(model.edit.mutesAudio)
            Button("Import soundtrack…") { model.chooseSoundtrack() }
                .controlSize(.small)
            Button("Export audio…") { model.exportEditedAudio() }
                .controlSize(.small)
                .disabled(model.edit.mutesAudio)
            Text("Mute silences preview and export. Mix to mono is applied when you export.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    func overlayPlacementGrid(selection: Binding<OverlayPlacement>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            overlayPlacementRow([.topLeading, .top, .topTrailing], selection: selection)
            overlayPlacementRow([.bottomLeading, .bottom, .bottomTrailing], selection: selection)
        }
    }

    private func overlayPlacementRow(
        _ slots: [OverlayPlacement],
        selection: Binding<OverlayPlacement>
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(slots) { slot in
                Button(slot.title) { selection.wrappedValue = slot }
                    .buttonStyle(.bordered)
                    .tint(selection.wrappedValue == slot ? .accentColor : .secondary)
                    .controlSize(.small)
            }
        }
    }
}
