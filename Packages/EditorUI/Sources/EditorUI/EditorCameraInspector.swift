import AnnotationModel
import SwiftUI

/// The perspective camera's controls (docs/09 U1.2).
///
/// Presets first, sliders second: the useful cameras are a small family of leans, and
/// asking someone to find one by dragging five sliders is asking them not to use it.
struct EditorCameraInspector: View {
    @Bindable var model: EditorDocumentModel

    private var spec: AnnotationCameraSpec {
        model.document.camera ?? .identity
    }

    private var isEnabled: Bool {
        model.document.camera != nil
    }

    var body: some View {
        Section("Perspective") {
            Toggle("Tilt the capture", isOn: enabledBinding)

            if isEnabled {
                presets
                slider(
                    "Tilt",
                    binding: tiltBinding,
                    range: -AnnotationCameraSpec.maximumTilt
                        ... AnnotationCameraSpec.maximumTilt,
                    suffix: "°"
                )
                slider(
                    "Orbit",
                    binding: orbitBinding,
                    range: -AnnotationCameraSpec.maximumTilt
                        ... AnnotationCameraSpec.maximumTilt,
                    suffix: "°"
                )
                slider("Roll", binding: rollBinding, range: -180 ... 180, suffix: "°")
                slider(
                    "Lens",
                    binding: fieldOfViewBinding,
                    range: AnnotationCameraSpec.minimumFieldOfView ... AnnotationCameraSpec.maximumFieldOfView,
                    suffix: "°"
                )
                .help("A narrow lens flattens the perspective; a wide one exaggerates it.")
                slider(
                    "Zoom",
                    binding: zoomBinding,
                    range: AnnotationCameraSpec.minimumZoom ... AnnotationCameraSpec.maximumZoom,
                    suffix: "×",
                    decimals: 2
                )
                slider("Pan X", binding: panXBinding, range: -0.5 ... 0.5, suffix: "", decimals: 2)
                slider("Pan Y", binding: panYBinding, range: -0.5 ... 0.5, suffix: "", decimals: 2)
                Button("Reset") { model.applyCamera(.identity) }
            }
        }
    }

    private var presets: some View {
        Picker("Angle", selection: Binding(
            get: { "" },
            set: { id in
                switch id {
                case "lean": model.applyCamera(.lean)
                case "hero": model.applyCamera(.hero)
                case "overhead": model.applyCamera(.overhead)
                default: break
                }
            }
        )) {
            Text("Preset…").tag("")
            Text("Lean").tag("lean")
            Text("Hero").tag("hero")
            Text("Overhead").tag("overhead")
        }
    }

    private func slider(
        _ title: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        decimals: Int = 0
    ) -> some View {
        Slider(value: binding, in: range) {
            Text("\(title) \(binding.wrappedValue, specifier: "%.\(decimals)f")\(suffix)")
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { on in
                if on {
                    model.applyCamera(.lean)
                } else {
                    model.clearCamera()
                }
            }
        )
    }

    private func binding(
        _ keyPath: WritableKeyPath<AnnotationCameraSpec, CGFloat>
    ) -> Binding<Double> {
        Binding(
            get: { spec[keyPath: keyPath] },
            set: { value in
                var next = spec
                next[keyPath: keyPath] = value
                model.applyCamera(next)
            }
        )
    }

    private var tiltBinding: Binding<Double> {
        binding(\.tiltDegrees)
    }

    private var orbitBinding: Binding<Double> {
        binding(\.orbitDegrees)
    }

    private var rollBinding: Binding<Double> {
        binding(\.rollDegrees)
    }

    private var fieldOfViewBinding: Binding<Double> {
        binding(\.fieldOfViewDegrees)
    }

    private var zoomBinding: Binding<Double> {
        binding(\.zoom)
    }

    private var panXBinding: Binding<Double> {
        Binding(
            get: { spec.pan.x },
            set: { value in
                var next = spec
                next.pan.x = value
                model.applyCamera(next)
            }
        )
    }

    private var panYBinding: Binding<Double> {
        Binding(
            get: { spec.pan.y },
            set: { value in
                var next = spec
                next.pan.y = value
                model.applyCamera(next)
            }
        )
    }
}
