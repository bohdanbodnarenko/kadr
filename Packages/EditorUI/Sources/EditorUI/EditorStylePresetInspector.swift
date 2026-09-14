import AnnotationModel
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        EditorInspectorSection(title: "Look", key: "look") {
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
                Button("Export…") { exportCurrent() }
                    .disabled(!hasAnyChrome)
                Button("Import…") { importPreset() }
            }

            Button {
                model.clearStylePreset()
                appliedID = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: matchedPreset == nil && !hasAnyChrome
                        ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(matchedPreset == nil && !hasAnyChrome
                            ? Color.accentColor : .secondary)
                    Text("None")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove the current look")

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
                if preset.id == matchedPreset?.id {
                    model.clearStylePreset()
                    appliedID = nil
                } else {
                    model.applyStylePreset(preset)
                    appliedID = preset.id
                }
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

    private func exportCurrent() {
        let name = matchedPreset?.name ?? "Look"
        let transfer = StylePresetTransfer(preset: StylePreset(name: name, capturing: model.document))
        guard let data = try? transfer.encoded() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: StylePresetTransfer.typeIdentifier)]
        panel.nameFieldStringValue = "\(name).\(StylePresetTransfer.pathExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: StylePresetTransfer.typeIdentifier)]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let preset = try? StylePresetTransfer.decoding(data)
        else { return }
        presets = StylePreset.builtIn + store.add(preset)
        model.applyStylePreset(preset)
        appliedID = preset.id
    }
}
