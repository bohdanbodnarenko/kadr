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
        EditorInspectorSection(title: "Depth of Field", key: "depthOfField", startsOpen: false) {
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

                InspectorSlider(title: "Strength", value: radiusBinding, range: 0 ... 0.2)
                InspectorSlider(title: "Sharp area", value: focusBinding, range: 0 ... 1)
                InspectorSlider(title: "Falloff", value: falloffBinding, range: 0 ... 1.5)
                if spec.shape == .directional {
                    InspectorSlider(
                        title: "Direction",
                        value: angleBinding,
                        range: 0 ... 360,
                        format: .degrees
                    )
                }
                Toggle("Soften the middle instead", isOn: invertedBinding)
                Button("Reset") { model.applyProgressiveBlur(.focus) }
                Button("Obscure centre") { model.applyProgressiveBlur(.obscureCentre) }
            }
        }
    }

    /// What the metrics resolve against — the same rule the beautify panel uses.
    private var shortestEdge: CGFloat {
        let size = model.document.contentRect.size
        return max(min(size.width, size.height), 1)
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
