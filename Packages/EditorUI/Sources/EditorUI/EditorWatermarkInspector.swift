import AnnotationModel
import ControlKit
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
        EditorInspectorSection(
            title: "Watermark",
            key: "watermark",
            startsOpen: false,
            isEnabled: enabledBinding
        ) {
            controls
        }
        .onAppear { draftText = spec.text }
    }

    @ViewBuilder
    private var controls: some View {
        TextField(String(localized: "Text", bundle: .module), text: $draftText)
            .inspectorTextField()
            // The field is on screen, disabled, while the mark is off; seeding the
            // draft must not quietly switch the watermark on.
            .onSubmit {
                if isEnabled {
                    commit { $0.text = draftText }
                }
            }
            .onChange(of: draftText) { _, value in
                guard isEnabled, value != spec.text else { return }
                commit { $0.text = value }
            }

        InspectorToggleRow("Repeat across the image", isOn: tiledBinding)
            .help(Text("A repeated mark survives being cropped; a single one is a signature.", bundle: .module))

        if spec.isTiled {
            KadrSlider(
                title: "Spacing",
                value: spacingBinding,
                range: 1 ... 6,
                format: .multiplier
            )
        } else {
            InspectorRow("Corner") {
                BeautifyAlignmentPicker(alignment: placementBinding)
            }
        }

        KadrSlider(title: "Size", value: sizeBinding, range: 0.01 ... 0.15)
        KadrSlider(title: "Opacity", value: opacityBinding, range: 0 ... 1)
        KadrSlider(
            title: "Angle",
            value: rotationBinding,
            range: -90 ... 90,
            format: .degrees(signed: true)
        )
        InspectorColorRow("Color", selection: colourBinding)
    }

    /// What the metrics resolve against — the canvas, since a watermark covers all of it.
    private var shortestEdge: CGFloat {
        let size = model.document.canvasRect.size
        return max(min(size.width, size.height), 1)
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
