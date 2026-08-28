import AnnotationModel
import SwiftUI

/// The progressive blur's controls (docs/09 U1.3).
///
/// Named "Depth of field" rather than "Blur" in the UI, because the editor already has a
/// Blur tool and it means something completely different: that one is a redaction with a
/// security claim, this one is decoration. Two things called blur in one inspector is how
/// somebody redacts a password with a gradient.
struct EditorBlurInspector: View {
    @Bindable var model: EditorDocumentModel

    private var spec: ProgressiveBlurSpec {
        model.document.progressiveBlur ?? .focus
    }

    private var isEnabled: Bool {
        model.document.progressiveBlur != nil
    }

    var body: some View {
        Section("Depth of Field") {
            Toggle("Soften part of the image", isOn: enabledBinding)

            if isEnabled {
                Picker("Falloff", selection: shapeBinding) {
                    ForEach(ProgressiveBlurShape.allCases, id: \.self) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Covers", selection: extentBinding) {
                    ForEach(ProgressiveBlurExtent.allCases, id: \.self) { extent in
                        Text(extent.title).tag(extent)
                    }
                }

                Slider(value: radiusBinding, in: 0 ... 0.2, step: 0.005) {
                    Text("Strength \(percent(spec.radius))")
                }
                Slider(value: focusBinding, in: 0 ... 1, step: 0.01) {
                    Text("Sharp area \(Int(spec.focusRadius * 100))%")
                }
                Slider(value: falloffBinding, in: 0 ... 1.5, step: 0.01) {
                    Text("Falloff \(Int(spec.falloffRadius * 100))%")
                }
                if spec.shape == .directional {
                    Slider(value: angleBinding, in: 0 ... 360, step: 15) {
                        Text("Direction \(Int(spec.angleDegrees))°")
                    }
                }
                Toggle("Soften the middle instead", isOn: invertedBinding)
                Button("Reset") { model.applyProgressiveBlur(.focus) }
            }
        }
    }

    /// What the metrics resolve against — the same rule the beautify panel uses.
    private var shortestEdge: CGFloat {
        let size = model.document.contentRect.size
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
                    model.applyProgressiveBlur(.focus)
                } else {
                    model.clearProgressiveBlur()
                }
            }
        )
    }

    private func commit(_ change: (inout ProgressiveBlurSpec) -> Void) {
        var next = spec
        change(&next)
        model.applyProgressiveBlur(next)
    }

    private var shapeBinding: Binding<ProgressiveBlurShape> {
        Binding(get: { spec.shape }, set: { value in commit { $0.shape = value } })
    }

    private var extentBinding: Binding<ProgressiveBlurExtent> {
        Binding(get: { spec.extent }, set: { value in commit { $0.extent = value } })
    }

    private var radiusBinding: Binding<Double> {
        Binding(
            get: { spec.radius.fraction(shortestEdge: shortestEdge) },
            set: { value in commit { $0.radius = .relative(value) } }
        )
    }

    private var focusBinding: Binding<Double> {
        Binding(get: { spec.focusRadius }, set: { value in commit { $0.focusRadius = value } })
    }

    private var falloffBinding: Binding<Double> {
        Binding(get: { spec.falloffRadius }, set: { value in commit { $0.falloffRadius = value } })
    }

    private var angleBinding: Binding<Double> {
        Binding(get: { spec.angleDegrees }, set: { value in commit { $0.angleDegrees = value } })
    }

    private var invertedBinding: Binding<Bool> {
        Binding(get: { spec.isInverted }, set: { value in commit { $0.isInverted = value } })
    }
}
