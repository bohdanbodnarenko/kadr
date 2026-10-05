import StudioSession
import SwiftUI

/// The recording's sound, and anything put in its place (docs/09 U3.6).
@MainActor
extension StudioInspector {
    var audioSection: some View {
        Section {
            Toggle(String(localized: "Mute", bundle: .module), isOn: Binding(
                get: { model.edit.mutesAudio },
                set: { value in model.change { $0.mutesAudio = value } }
            ))
            Toggle(String(localized: "Mix to mono", bundle: .module), isOn: Binding(
                get: { model.edit.mixesToMono },
                set: { value in model.change { $0.mixesToMono = value } }
            ))
            .disabled(model.edit.mutesAudio)
            soundtrackRow
            Button(String(localized: "Export Audio…", bundle: .module)) { model.exportEditedAudio() }
                .disabled(model.edit.mutesAudio)
        } header: {
            Text("Audio", bundle: .module)
        } footer: {
            Text(soundtrackSummary)
        }
    }

    /// The soundtrack as one row: what is playing, and the way to change it.
    @ViewBuilder
    private var soundtrackRow: some View {
        if let name = model.edit.soundtrackDisplayName ?? model.edit.soundtrackFileName {
            LabeledContent(String(localized: "Soundtrack", bundle: .module)) {
                HStack(spacing: 8) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(String(localized: "Remove", bundle: .module), role: .destructive) { model.removeSoundtrack()
                    }
                    .buttonStyle(.link)
                }
            }
        } else {
            Button(String(localized: "Import Soundtrack…", bundle: .module)) { model.chooseSoundtrack() }
        }
    }

    private var soundtrackSummary: String {
        if model.edit.mutesAudio {
            return String(localized: "Muted in the preview and in the export.", bundle: .module)
        }
        if model.edit.soundtrackDisplayName ?? model.edit.soundtrackFileName != nil {
            return String(localized: "The imported track plays instead of the recording's own audio.", bundle: .module)
        }
        return String(localized: "The recording's own audio, cut and sped with the picture.", bundle: .module)
    }
}
