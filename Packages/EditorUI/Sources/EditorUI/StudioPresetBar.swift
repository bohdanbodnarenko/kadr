import ControlKit
import StudioSession
import SwiftUI

/// Saved looks — apply, save, delete, pick a default for the next recording (docs/09 U3.5).
///
/// A row inside the Frame pane's first section, not a bar pinned above the inspector: the
/// name of the current look belongs beside the controls that change it, and one column
/// under two stacked toolbars is a column with no room left.
struct StudioPresetBar: View {
    let model: StudioDocumentModel

    @State private var isNaming = false
    @State private var draftName = ""
    @State private var pendingDeletion: StudioPreset?

    var body: some View {
        HStack(spacing: 6) {
            menu
            if canDeleteApplied {
                barIcon("trash", help: "Delete \(model.appliedPresetName ?? "this look")") {
                    pendingDeletion = model.allPresets.first { $0.id == model.appliedPresetID }
                }
            }
            barIcon("plus", help: "Save the current look as a preset") {
                draftName = model.appliedPresetName ?? ""
                isNaming = true
            }
        }
        .alert("Save this look", isPresented: $isNaming) {
            TextField(String(localized: "Name", bundle: .module), text: $draftName)
            Button(String(localized: "Save", bundle: .module)) { model.saveCurrentPreset(named: draftName) }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text(
                "Saves the canvas, camera bubble, pointer and overlays. Cuts and zooms stay as they are.",
                bundle: .module
            )
        }
        .alert(
            "Delete this look?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: {
                    if !$0 {
                        pendingDeletion = nil
                    }
                }
            ),
            presenting: pendingDeletion
        ) { preset in
            Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                model.deletePreset(id: preset.id)
                pendingDeletion = nil
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) { pendingDeletion = nil }
        } message: { preset in
            Text("“\(preset.name)” will be removed. This recording will not change.", bundle: .module)
        }
    }

    private var canDeleteApplied: Bool {
        guard let id = model.appliedPresetID else { return false }
        return model.userPresets.contains { $0.id == id }
    }

    private var menuTitle: String {
        guard let name = model.appliedPresetName else { return "Presets…" }
        return model.isAppliedPresetEdited ? "\(name) (edited)" : name
    }

    private var menu: some View {
        Menu {
            Section(String(localized: "Built-in", bundle: .module)) {
                ForEach(StudioPreset.builtIn) { preset in
                    presetButton(preset)
                }
            }
            if !model.userPresets.isEmpty {
                Section(String(localized: "Saved", bundle: .module)) {
                    ForEach(model.userPresets) { preset in
                        presetButton(preset)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(menuTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, KadrSpace.medium)
            .padding(.vertical, 5)
            .background(
                .quaternary.opacity(0.45),
                in: RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous)
            )
        }
        .menuStyle(.button)
        .help(Text("Apply a saved look. Cuts and zooms are left alone.", bundle: .module))
    }

    private func presetButton(_ preset: StudioPreset) -> some View {
        Button {
            model.applyPreset(preset)
        } label: {
            if preset.id == model.appliedPresetID, !model.isAppliedPresetEdited {
                Label(presetRowTitle(preset), systemImage: "checkmark")
            } else {
                Text(presetRowTitle(preset))
            }
        }
        .contextMenu {
            Button(model.defaultPresetID == preset.id ? "Clear Default" : "Use as Default") {
                model.setDefaultPreset(id: model.defaultPresetID == preset.id ? nil : preset.id)
            }
            if model.userPresets.contains(where: { $0.id == preset.id }) {
                Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                    pendingDeletion = preset
                }
            }
        }
    }

    private func presetRowTitle(_ preset: StudioPreset) -> String {
        preset.id == model.defaultPresetID ? "\(preset.name) — default" : preset.name
    }

    private func barIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: KadrType.caption, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
