import AnnotationModel
import SwiftUI

/// Whole looks: apply one, save one, see which one you are wearing (docs/09 U1.5).
///
/// The "(edited)" state is the part that earns its keep. Without it the inspector shows the
/// name of the preset that was last *applied*, which stops being true the moment anything
/// is touched — and a label that is quietly wrong is worse than no label, because it is the
/// thing someone checks before overwriting a preset.
struct EditorStylePresetInspector: View {
    @Bindable var model: EditorDocumentModel

    @State private var presets: [StylePreset] = []
    @State private var isNaming = false
    @State private var draftName = ""
    /// The preset last applied, so "edited" can mean "differs from what you chose" rather
    /// than "differs from nothing".
    @State private var appliedID: UUID?

    private let store = StylePresetStore()

    var body: some View {
        Section("Look") {
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save…") {
                    draftName = matchedPreset?.name ?? ""
                    isNaming = true
                }
                .disabled(!hasAnyChrome)
            }

            ForEach(presets) { preset in
                row(preset)
            }
        }
        .onAppear { presets = store.all() }
        .alert("Save this look", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the background, perspective, depth of field and watermark together.")
        }
    }

    private func row(_ preset: StylePreset) -> some View {
        HStack {
            Button {
                model.applyStylePreset(preset)
                appliedID = preset.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: preset.id == matchedPreset?.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(preset.id == matchedPreset?.id ? Color.accentColor : .secondary)
                    Text(preset.name)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isUserPreset(preset) {
                Button(role: .destructive) {
                    presets = StylePreset.builtIn + store.remove(id: preset.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this look")
            }
        }
    }

    // MARK: - State

    private var hasAnyChrome: Bool {
        !StylePreset(name: "", capturing: model.document).isEmpty
    }

    private var matchedPreset: StylePreset? {
        model.document.matchingStylePreset(among: presets)
    }

    private var statusText: String {
        if let matched = matchedPreset {
            return matched.name
        }
        if let appliedID, let applied = presets.first(where: { $0.id == appliedID }) {
            return "\(applied.name) (edited)"
        }
        return hasAnyChrome ? "Custom" : "None"
    }

    private func isUserPreset(_ preset: StylePreset) -> Bool {
        !StylePreset.builtIn.contains { $0.id == preset.id }
    }

    private func saveCurrent() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let saved = StylePreset(name: name, capturing: model.document)
        presets = StylePreset.builtIn + store.add(saved)
        appliedID = saved.id
    }
}
