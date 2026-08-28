import AnnotationModel
import AppKit
import SwiftUI

/// Canvas chrome: padding, backdrop, corners, shadow, aspect, alignment, saved presets
/// (docs/03 §3 P2, docs/09 U1.1).
///
/// Lives as its own inspector section so it stays visible regardless of the pointer tool.
///
/// The sliders work in *percentages of the capture's shortest edge*, not points, because
/// that is what the model stores and what makes a preset carry between a tweet-sized crop
/// and a 5K screenshot. Showing points here would show a number that means something
/// different on every capture.
struct EditorBeautifyInspector: View {
    @Bindable var model: EditorDocumentModel
    @State private var saved: [BeautifyPresetStore.Saved] = []
    @State private var isNamingPreset = false
    @State private var newPresetName = ""

    private let presetStore = BeautifyPresetStore()

    private var spec: BeautifySpec {
        model.document.beautify ?? BeautifySpec(padding: .zero, cornerRadius: .zero, shadow: .none)
    }

    private var isEnabled: Bool {
        model.document.beautify != nil
    }

    /// What the metrics resolve against.
    private var shortestEdge: CGFloat {
        let size = model.document.contentRect.size
        return max(min(size.width, size.height), 1)
    }

    var body: some View {
        Section("Beautify") {
            Toggle("Add a background", isOn: enabledBinding)

            if isEnabled {
                presets
                Slider(value: paddingBinding, in: 0 ... 0.35, step: 0.005) {
                    Text("Padding \(percent(spec.padding))")
                }
                Slider(value: radiusBinding, in: 0 ... 0.15, step: 0.0025) {
                    Text("Corners \(percent(spec.cornerRadius))")
                }
                Toggle("Shadow", isOn: shadowBinding)
                Picker("Aspect", selection: aspectBinding) {
                    ForEach(BeautifyAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                placement
                border
                BeautifyBackdropPicker(backdrop: spec.backdrop) { backdrop in
                    commit { $0.backdrop = backdrop }
                }
                if !saved.isEmpty {
                    savedPresets
                }
            }
        }
        .onAppear { saved = presetStore.load() }
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") { saveCurrentPreset() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Where the capture sits, and whether it runs off the edge when it gets there.
    private var placement: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text("Placement")
                Spacer()
                BeautifyAlignmentPicker(alignment: alignmentBinding)
            }
            Toggle("Bleed off the edge", isOn: sticksBinding)
                .disabled(spec.alignment == .center)
                .help("Removes the padding on the edges the capture touches, and squares the corners there.")
        }
    }

    /// The ring around the capture. Part of the card, so it lives with the card's controls.
    @ViewBuilder
    private var border: some View {
        Toggle("Border", isOn: borderBinding)
        if spec.border.isEnabled {
            Slider(value: borderThicknessBinding, in: 0.002 ... 0.06, step: 0.002) {
                Text("Thickness \(percent(spec.border.thickness))")
            }
            ColorPicker("Border colour", selection: borderColourBinding)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Look", selection: Binding(
                get: { "" },
                set: { id in
                    guard let preset = BeautifyPreset.builtIn.first(where: { $0.id == id }) else { return }
                    model.applyBeautify(preset.spec)
                }
            )) {
                Text("Built-in…").tag("")
                ForEach(BeautifyPreset.builtIn) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            Button("Save current look…") {
                newPresetName = ""
                isNamingPreset = true
            }
        }
    }

    private var savedPresets: some View {
        ForEach(saved) { preset in
            HStack {
                Button(preset.name) { model.applyBeautify(preset.spec) }
                    .buttonStyle(.plain)
                Spacer()
                Button(role: .destructive) {
                    presetStore.remove(id: preset.id)
                    saved = presetStore.load()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { on in
                if on {
                    model.applyBeautify(.cleanWhite)
                } else {
                    model.clearBeautify()
                }
            }
        )
    }

    private var paddingBinding: Binding<Double> {
        Binding(
            get: { spec.padding.fraction(shortestEdge: shortestEdge) },
            set: { value in commit { $0.padding = .relative(value) } }
        )
    }

    private var radiusBinding: Binding<Double> {
        Binding(
            get: { spec.cornerRadius.fraction(shortestEdge: shortestEdge) },
            set: { value in commit { $0.cornerRadius = .relative(value) } }
        )
    }

    private var shadowBinding: Binding<Bool> {
        Binding(
            get: { spec.shadow.isEnabled },
            set: { on in commit { $0.shadow = on ? .soft : .none } }
        )
    }

    private var aspectBinding: Binding<BeautifyAspect> {
        Binding(
            get: { spec.aspect },
            set: { value in commit { $0.aspect = value } }
        )
    }

    private var alignmentBinding: Binding<BeautifyAlignment> {
        Binding(
            get: { spec.alignment },
            set: { value in commit { $0.alignment = value } }
        )
    }

    private var sticksBinding: Binding<Bool> {
        Binding(
            get: { spec.sticksToEdges },
            set: { value in commit { $0.sticksToEdges = value } }
        )
    }

    private var borderBinding: Binding<Bool> {
        Binding(
            get: { spec.border.isEnabled },
            set: { on in commit { $0.border = on ? .mount : .none } }
        )
    }

    private var borderThicknessBinding: Binding<Double> {
        Binding(
            get: { spec.border.thickness.fraction(shortestEdge: shortestEdge) },
            set: { value in commit { $0.border.thickness = .relative(value) } }
        )
    }

    private var borderColourBinding: Binding<Color> {
        Binding(
            get: { Color(spec.border.color) },
            set: { value in commit { $0.border.color = AnnotationColor(value) } }
        )
    }

    private func percent(_ metric: BeautifyMetric) -> String {
        "\(Int((metric.fraction(shortestEdge: shortestEdge) * 100).rounded()))%"
    }

    private func commit(_ change: (inout BeautifySpec) -> Void) {
        var next = spec
        change(&next)
        model.applyBeautify(next)
    }

    private func saveCurrentPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let current = model.document.beautify else { return }
        presetStore.add(name: name, spec: current)
        saved = presetStore.load()
    }
}
