import AnnotationModel
import SwiftUI

/// The watermark's controls (docs/09 U1.4).
struct EditorWatermarkInspector: View {
    @Bindable var model: EditorDocumentModel

    /// The text field's own copy, so typing does not commit a document edit per keystroke
    /// before the user has finished the word.
    @State private var draftText = ""

    private var spec: WatermarkSpec {
        model.document.watermark ?? WatermarkSpec()
    }

    private var isEnabled: Bool {
        model.document.watermark != nil
    }

    var body: some View {
        Section("Watermark") {
            Toggle("Mark the image", isOn: enabledBinding)

            if isEnabled {
                TextField("Text", text: $draftText)
                    .onSubmit { commit { $0.text = draftText } }
                    .onChange(of: draftText) { _, value in commit { $0.text = value } }

                Toggle("Repeat across the image", isOn: tiledBinding)
                    .help("A repeated mark survives being cropped; a single one is a signature.")

                if spec.isTiled {
                    Slider(value: spacingBinding, in: 1 ... 6, step: 0.1) {
                        Text("Spacing \(spec.spacing, specifier: "%.1f")×")
                    }
                } else {
                    HStack(alignment: .top) {
                        Text("Corner")
                        Spacer()
                        BeautifyAlignmentPicker(alignment: placementBinding)
                    }
                }

                Slider(value: sizeBinding, in: 0.01 ... 0.15, step: 0.005) {
                    Text("Size \(percent(spec.fontSize))")
                }
                Slider(value: opacityBinding, in: 0 ... 1, step: 0.05) {
                    Text("Opacity \(Int(spec.opacity * 100))%")
                }
                Slider(value: rotationBinding, in: -90 ... 90, step: 5) {
                    Text("Angle \(Int(spec.rotationDegrees))°")
                }
                ColorPicker("Colour", selection: colourBinding)
            }
        }
        .onAppear { draftText = spec.text }
    }

    /// What the metrics resolve against — the canvas, since a watermark covers all of it.
    private var shortestEdge: CGFloat {
        let size = model.document.canvasRect.size
        return max(min(size.width, size.height), 1)
    }

    private func percent(_ metric: BeautifyMetric) -> String {
        "\(Int((metric.fraction(shortestEdge: shortestEdge) * 100).rounded()))%"
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { on in
                if on {
                    draftText = "Confidential"
                    model.applyWatermark(.signature("Confidential"))
                } else {
                    model.clearWatermark()
                }
            }
        )
    }

    private func commit(_ change: (inout WatermarkSpec) -> Void) {
        var next = spec
        change(&next)
        model.applyWatermark(next)
    }

    private var tiledBinding: Binding<Bool> {
        Binding(get: { spec.isTiled }, set: { value in commit { $0.isTiled = value } })
    }

    private var spacingBinding: Binding<Double> {
        Binding(get: { spec.spacing }, set: { value in commit { $0.spacing = value } })
    }

    private var placementBinding: Binding<BeautifyAlignment> {
        Binding(get: { spec.placement }, set: { value in commit { $0.placement = value } })
    }

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { spec.fontSize.fraction(shortestEdge: shortestEdge) },
            set: { value in commit { $0.fontSize = .relative(value) } }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { spec.opacity }, set: { value in commit { $0.opacity = value } })
    }

    private var rotationBinding: Binding<Double> {
        Binding(get: { spec.rotationDegrees }, set: { value in commit { $0.rotationDegrees = value } })
    }

    private var colourBinding: Binding<Color> {
        Binding(
            get: { Color(spec.color) },
            set: { value in commit { $0.color = AnnotationColor(value) } }
        )
    }
}
