import AnnotationModel
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Canvas chrome: padding, backdrop, corners, shadow, aspect, saved presets (docs/03 §3 P2).
///
/// Lives as its own inspector section so it stays visible regardless of the pointer tool.
struct EditorBeautifyInspector: View {
    @Bindable var model: EditorDocumentModel
    @State private var saved: [BeautifyPresetStore.Saved] = []
    @State private var isNamingPreset = false
    @State private var newPresetName = ""

    private let presetStore = BeautifyPresetStore()

    private var spec: BeautifySpec {
        model.document.beautify ?? BeautifySpec(padding: 0, cornerRadius: 0, shadow: .none)
    }

    private var isEnabled: Bool {
        model.document.beautify != nil
    }

    var body: some View {
        Section("Beautify") {
            Toggle("Add a background", isOn: enabledBinding)

            if isEnabled {
                presets
                Slider(value: paddingBinding, in: 0 ... 120, step: 4) {
                    Text("Padding \(Int(spec.padding)) pt")
                }
                Slider(value: radiusBinding, in: 0 ... 48, step: 1) {
                    Text("Corners \(Int(spec.cornerRadius)) pt")
                }
                Toggle("Shadow", isOn: shadowBinding)
                Picker("Aspect", selection: aspectBinding) {
                    ForEach(BeautifyAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                Toggle("Centre on the canvas", isOn: autoBalanceBinding)
                backdrop
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

    @ViewBuilder
    private var backdrop: some View {
        Picker("Backdrop", selection: backdropKindBinding) {
            Text("Solid").tag(0)
            Text("Gradient").tag(1)
            Text("Image").tag(2)
        }
        .pickerStyle(.segmented)

        switch spec.backdrop {
        case let .solid(colour):
            ColorPicker("Colour", selection: Binding(
                get: { Color(colour) },
                set: { newValue in commit { $0.backdrop = .solid(AnnotationColor(newValue)) } }
            ))
        case let .gradient(start, end, _):
            ColorPicker("Top", selection: Binding(
                get: { Color(start) },
                set: { newValue in
                    commit { current in
                        if case let .gradient(_, endColour, angle) = current.backdrop {
                            current.backdrop = .gradient(
                                start: AnnotationColor(newValue),
                                end: endColour,
                                angleDegrees: angle
                            )
                        }
                    }
                }
            ))
            ColorPicker("Bottom", selection: Binding(
                get: { Color(end) },
                set: { newValue in
                    commit { current in
                        if case let .gradient(startColour, _, angle) = current.backdrop {
                            current.backdrop = .gradient(
                                start: startColour,
                                end: AnnotationColor(newValue),
                                angleDegrees: angle
                            )
                        }
                    }
                }
            ))
        case .image:
            Button("Choose Image…") { pickImage() }
        }
    }

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
            get: { spec.padding },
            set: { value in commit { $0.padding = value } }
        )
    }

    private var radiusBinding: Binding<Double> {
        Binding(
            get: { spec.cornerRadius },
            set: { value in commit { $0.cornerRadius = value } }
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

    private var autoBalanceBinding: Binding<Bool> {
        Binding(
            get: { spec.autoBalance },
            set: { value in commit { $0.autoBalance = value } }
        )
    }

    private var backdropKindBinding: Binding<Int> {
        Binding(
            get: {
                switch spec.backdrop {
                case .solid: 0
                case .gradient: 1
                case .image: 2
                }
            },
            set: { kind in
                commit { current in
                    switch kind {
                    case 1:
                        current.backdrop = .gradient(start: .white, end: .black, angleDegrees: 90)
                    case 2:
                        current.backdrop = .image(path: "")
                    default:
                        current.backdrop = .solid(.white)
                    }
                }
            }
        )
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

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = Self.copiedBackdrop(from: url) ?? url.path
        commit { $0.backdrop = .image(path: destination) }
    }

    /// Copies the chosen image into Application Support so the `.kadr` file does not
    /// depend on a Desktop file the user might later throw away.
    private static func copiedBackdrop(from url: URL) -> String? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let folder = support.appendingPathComponent("Kadr/BeautifyBackdrops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }
}
