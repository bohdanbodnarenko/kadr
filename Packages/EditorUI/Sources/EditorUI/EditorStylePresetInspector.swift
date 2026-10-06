import AnnotationModel
import AppKit
import ControlKit
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
        // Captured once per evaluation. Every row, the header and the status line all ask
        // "which look is this?", and each asking used to rebuild the document's look from
        // its commands and compare it against every preset again.
        let look = LookState(document: model.document, presets: presets)
        EditorInspectorSection(title: "Look", key: "look", accessory: { headerAccessory(look) }, content: {
            VStack(spacing: 0) {
                EditorLookRow(
                    name: "None",
                    isActive: look.matched == nil && !look.hasAnyChrome,
                    onDelete: nil
                ) {
                    model.clearStylePreset()
                    appliedID = nil
                }
                .help(Text("Remove the current look", bundle: .module))

                ForEach(presets) { preset in
                    row(preset, look: look)
                }
            }
        })
        .onAppear { presets = store.all() }
        .alert("Save this look", isPresented: $isNaming) {
            TextField(String(localized: "Name", bundle: .module), text: $draftName)
            Button(String(localized: "Save", bundle: .module)) { saveCurrent() }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text("Saves the background, perspective, depth of field and watermark together.", bundle: .module)
        }
    }

    /// What is being worn, and the save / export / import actions in one menu rather than
    /// three buttons squeezed into a row.
    private func headerAccessory(_ look: LookState) -> some View {
        HStack(spacing: 2) {
            Text(statusText(look))
                .font(.inspectorNote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Menu {
                Button(String(localized: "Save Look…", bundle: .module)) {
                    draftName = look.matched?.name ?? ""
                    isNaming = true
                }
                .disabled(!look.hasAnyChrome)
                Button(String(localized: "Export Look…", bundle: .module)) { exportCurrent() }
                    .disabled(!look.hasAnyChrome)
                Button(String(localized: "Use for New Captures", bundle: .module)) { saveAsDefault() }
                    .disabled(!look.hasAnyChrome)
                Divider()
                Button(String(localized: "Import Look…", bundle: .module)) { importPreset() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: KadrType.title))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Save, export or import looks", bundle: .module))
            .accessibilityLabel(Text("Look actions", bundle: .module))
        }
    }

    private func row(_ preset: StylePreset, look: LookState) -> some View {
        EditorLookRow(
            name: preset.name,
            isActive: preset.id == look.matched?.id,
            onDelete: isUserPreset(preset)
                ? { presets = StylePreset.builtIn + store.remove(id: preset.id) }
                : nil
        ) {
            if preset.id == look.matched?.id {
                model.clearStylePreset()
                appliedID = nil
            } else {
                model.applyStylePreset(preset)
                appliedID = preset.id
            }
        }
    }

    // MARK: - State

    /// The document's look, captured once, and the preset it matches.
    private struct LookState {
        let hasAnyChrome: Bool
        let matched: StylePreset?

        init(document: AnnotationDocument, presets: [StylePreset]) {
            let current = StylePreset(name: "", capturing: document)
            hasAnyChrome = !current.isEmpty
            // The same test as `StylePreset.matches`, against one capture instead of one per
            // preset.
            let appearance = current.appearance
            matched = presets.first { $0.appearance == appearance }
        }
    }

    private func statusText(_ look: LookState) -> String {
        if let matched = look.matched {
            return matched.name
        }
        if let appliedID, let applied = presets.first(where: { $0.id == appliedID }) {
            return "\(applied.name) (edited)"
        }
        return look.hasAnyChrome ? "Custom" : "None"
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
        let name = model.document.matchingStylePreset(among: presets)?.name ?? "Look"
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var imported: StylePreset?
        var failures = 0
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                let preset = try StylePresetTransfer.decoding(data)
                presets = StylePreset.builtIn + store.addImported(preset)
                imported = preset
            } catch {
                failures += 1
            }
        }
        if let imported {
            model.applyStylePreset(imported)
            appliedID = imported.id
        }
        if failures > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failures == 1
                ? "One look could not be imported."
                : "\(failures) looks could not be imported."
            alert.runModal()
        }
    }

    private func saveAsDefault() {
        let preset = StylePreset(name: "New captures", capturing: model.document)
        do {
            try DefaultCaptureLook.save(preset)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not save the default look."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
                        .font(.system(size: KadrType.caption, weight: .semibold))
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
        .padding(.horizontal, KadrSpace.small)
        .background(
            RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous)
                .fill(isHovering ? InspectorControlPalette.hoverFill : .clear)
        )
        .padding(.horizontal, -6)
        .onHover { isHovering = $0 }
    }
}
