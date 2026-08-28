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
        Section("Beautify") {
            Toggle("Add a background", isOn: enabledBinding)

            if isEnabled {
                InspectorSlider(title: "Padding", value: paddingBinding, range: 0 ... 0.35)
                InspectorSlider(title: "Corners", value: radiusBinding, range: 0 ... 0.15)
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
            }
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
            InspectorSlider(title: "Thickness", value: borderThicknessBinding, range: 0.002 ... 0.06)
            ColorPicker("Border colour", selection: borderColourBinding)
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

    private func commit(_ change: (inout BeautifySpec) -> Void) {
        var next = spec
        change(&next)
        model.applyBeautify(next)
    }
}
