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
        EditorInspectorSection(title: "Look", key: "look", accessory: { headerAccessory }, content: {
            VStack(spacing: 0) {
                EditorLookRow(
                    name: "None",
                    isActive: matchedPreset == nil && !hasAnyChrome,
                    onDelete: nil
                ) {
                    model.clearStylePreset()
                    appliedID = nil
                }
                .help("Remove the current look")

                ForEach(presets) { preset in
                    row(preset)
                }
            }
        })
        .onAppear { presets = store.all() }
        .alert("Save this look", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the background, perspective, depth of field and watermark together.")
        }
    }

    /// What is being worn, and the save / export / import actions in one menu rather than
    /// three buttons squeezed into a row.
    private var headerAccessory: some View {
        HStack(spacing: 2) {
            Text(statusText)
                .font(.inspectorNote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Menu {
                Button("Save Look…") {
                    draftName = matchedPreset?.name ?? ""
                    isNaming = true
                }
                .disabled(!hasAnyChrome)
                Button("Export Look…") { exportCurrent() }
                    .disabled(!hasAnyChrome)
                Divider()
                Button("Import Look…") { importPreset() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save, export or import looks")
            .accessibilityLabel("Look actions")
        }
    }

    private func row(_ preset: StylePreset) -> some View {
        EditorLookRow(
            name: preset.name,
            isActive: preset.id == matchedPreset?.id,
            onDelete: isUserPreset(preset)
                ? { presets = StylePreset.builtIn + store.remove(id: preset.id) }
                : nil
        ) {
            if preset.id == matchedPreset?.id {
                model.clearStylePreset()
                appliedID = nil
            } else {
                model.applyStylePreset(preset)
                appliedID = preset.id
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

/// One look in the list: a checkmark for the one being worn, a hover wash, and delete for
/// the user's own.
private struct EditorLookRow: View {
    let name: String
    let isActive: Bool
    let onDelete: (() -> Void)?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isActive ? 1 : 0)
                        .frame(width: 14)
                    Text(name)
                        .font(.inspectorLabel)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: InspectorMetrics.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if let onDelete {
                InspectorIconButton(systemName: "trash", help: "Delete this look", action: onDelete)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? InspectorControlPalette.hoverFill : .clear)
        )
        .padding(.horizontal, -6)
        .onHover { isHovering = $0 }
    }
}
