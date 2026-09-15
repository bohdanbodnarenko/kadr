import AnnotationModel
import AppKit
import SwiftUI

/// Canvas chrome: padding, backdrop, corners, shadow, aspect, alignment, border
/// (docs/03 §3 P2, docs/09 U1.1, U1.4).
///
/// Lives as its own inspector section so it stays visible regardless of the pointer tool.
///
/// The sliders work in *percentages of the capture's shortest edge*, not points, because
/// that is what the model stores and what makes a preset carry between a tweet-sized crop
/// and a 5K screenshot. Showing points here would show a number that means something
/// different on every capture.
///
/// Whole looks are saved and applied in `EditorStylePresetInspector`, not here: a
/// background alone is not a look (docs/09 U1.5).
struct EditorBeautifyInspector: View {
    @Bindable var model: EditorDocumentModel

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
        EditorInspectorSection(
            title: "Beautify",
            key: "beautify",
            startsOpen: false,
            isEnabled: enabledBinding
        ) {
            InspectorSlider(title: "Padding", value: paddingBinding, range: 0 ... 0.35)
            InspectorSlider(title: "Corners", value: radiusBinding, range: 0 ... 0.15)
            InspectorToggleRow("Shadow", isOn: shadowBinding)
            if spec.shadow.isEnabled {
                InspectorSegmented(
                    BeautifyShadowStyle.allCases,
                    selection: shadowStyleBinding,
                    title: \.title
                )
                InspectorSlider(title: "Strength", value: shadowStrengthBinding, range: 0.15 ... 1)
            }
            InspectorRow("Aspect") {
                Picker("Aspect", selection: aspectBinding) {
                    ForEach(BeautifyAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .inspectorMenuPicker()
            }
            placement
            border
            InspectorStackedRow("Backdrop") {
                BeautifyBackdropPicker(backdrop: spec.backdrop) { backdrop in
                    commit { $0.backdrop = backdrop }
                }
            }
        }
    }

    /// Where the capture sits, and whether it runs off the edge when it gets there.
    @ViewBuilder
    private var placement: some View {
        InspectorRow("Placement") {
            BeautifyAlignmentPicker(alignment: alignmentBinding)
        }
        InspectorToggleRow("Bleed off the edge", isOn: sticksBinding)
            .disabled(spec.alignment == .center)
            .help("Removes the padding on the edges the capture touches, and squares the corners there.")
    }

    /// The ring around the capture. Part of the card, so it lives with the card's controls.
    @ViewBuilder
    private var border: some View {
        InspectorToggleRow("Border", isOn: borderBinding)
        if spec.border.isEnabled {
            InspectorSlider(title: "Thickness", value: borderThicknessBinding, range: 0.002 ... 0.06)
            InspectorColorRow("Border colour", selection: borderColourBinding)
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { on in
                if on {
                    // A soft gradient rather than Clean White: flat white padding on the
                    // light workspace read as a stray container behind the screenshot, not
                    // as a background. Clean White is still one click away under Look.
                    model.applyBeautify(BeautifySpec(backdrop: .gradient(BeautifyPalette.gradients[5])))
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

    private var shadowStyleBinding: Binding<BeautifyShadowStyle> {
        Binding(
            get: { spec.shadow.style },
            set: { value in
                commit { $0.shadow = value.shadow.scaled(strength: spec.shadow.strength) }
            }
        )
    }

    private var shadowStrengthBinding: Binding<Double> {
        Binding(
            get: { spec.shadow.strength },
            set: { value in
                commit { $0.shadow = spec.shadow.style.shadow.scaled(strength: value) }
            }
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

    private func commit(_ change: (inout BeautifySpec) -> Void) {
        var next = spec
        change(&next)
        model.applyBeautify(next)
    }
}
