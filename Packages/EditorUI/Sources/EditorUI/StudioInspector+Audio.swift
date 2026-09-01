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
            Button("Import soundtrack…") { model.chooseSoundtrack() }
                .controlSize(.small)
            Button("Export audio…") { model.exportEditedAudio() }
                .controlSize(.small)
            Text("Export the edited soundtrack, clean it in another tool, then drop the file back in.")
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
