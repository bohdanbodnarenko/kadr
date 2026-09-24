import AnnotationModel
import ControlKit
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
        EditorInspectorSection(
            title: "Perspective",
            key: "perspective",
            startsOpen: false,
            isEnabled: enabledBinding,
            accessory: {
                if isEnabled {
                    InspectorIconButton(systemName: "arrow.counterclockwise", help: "Reset perspective") {
                        model.applyCamera(.identity)
                    }
                }
            },
            content: { controls }
        )
    }

    @ViewBuilder
    private var controls: some View {
        presets
        KadrSlider(
            title: "Tilt",
            value: tiltBinding,
            range: -AnnotationCameraSpec.maximumTilt ... AnnotationCameraSpec.maximumTilt,
            format: .degrees(signed: true)
        )
        KadrSlider(
            title: "Orbit",
            value: orbitBinding,
            range: -AnnotationCameraSpec.maximumTilt ... AnnotationCameraSpec.maximumTilt,
            format: .degrees(signed: true)
        )
        KadrSlider(
            title: "Roll",
            value: rollBinding,
            range: -180 ... 180,
            format: .degrees(signed: true)
        )
        KadrSlider(
            title: "Lens",
            value: fieldOfViewBinding,
            range: AnnotationCameraSpec.minimumFieldOfView
                ... AnnotationCameraSpec.maximumFieldOfView,
            format: .degrees
        )
        .help("A narrow lens flattens the perspective; a wide one exaggerates it.")
        KadrSlider(
            title: "Zoom",
            value: zoomBinding,
            range: AnnotationCameraSpec.minimumZoom ... AnnotationCameraSpec.maximumZoom,
            format: .multiplier
        )
        KadrSlider(
            title: "Pan X",
            value: panXBinding,
            range: -0.5 ... 0.5,
            format: .percent(signed: true)
        )
        KadrSlider(
            title: "Pan Y",
            value: panYBinding,
            range: -0.5 ... 0.5,
            format: .percent(signed: true)
        )
    }

    private var presets: some View {
        InspectorRow("Preset") {
            anglePicker
                .inspectorMenuPicker()
        }
    }

    private var anglePicker: some View {
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
