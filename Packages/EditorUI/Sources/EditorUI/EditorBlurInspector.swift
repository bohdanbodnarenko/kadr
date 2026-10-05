import AnnotationModel
import ControlKit
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
        EditorInspectorSection(
            title: "Depth of Field",
            key: "depthOfField",
            startsOpen: false,
            isEnabled: enabledBinding,
            accessory: {
                if isEnabled {
                    InspectorIconButton(systemName: "arrow.counterclockwise", help: "Reset depth of field") {
                        model.applyProgressiveBlur(.focus)
                    }
                }
            },
            content: { controls }
        )
    }

    @ViewBuilder
    private var controls: some View {
        InspectorSegmented(Array(ProgressiveBlurShape.allCases), selection: shapeBinding, title: \.title)

        InspectorRow("Covers") {
            Picker("Covers", selection: extentBinding) {
                ForEach(ProgressiveBlurExtent.allCases, id: \.self) { extent in
                    Text(extent.title).tag(extent)
                }
            }
            .inspectorMenuPicker()
        }

        KadrSlider(title: "Strength", value: radiusBinding, range: 0 ... 0.2)
        KadrSlider(title: "Sharp area", value: focusBinding, range: 0 ... 1)
        KadrSlider(title: "Falloff", value: falloffBinding, range: 0 ... 1.5)
        if spec.shape == .directional {
            KadrSlider(
                title: "Direction",
                value: angleBinding,
                range: 0 ... 360,
                format: .degrees
            )
        }
        InspectorToggleRow("Soften the middle instead", isOn: invertedBinding)
        InspectorRow("Focus") {
            FocusPad(point: centerBinding)
                .frame(width: 72, height: 48)
                .help("Where the sharp area sits")
        }
        Button("Obscure Centre") { model.applyProgressiveBlur(.obscureCentre) }
            .buttonStyle(InspectorButtonStyle())
        Button("Tilt Shift") { model.applyProgressiveBlur(.tiltShift) }
            .buttonStyle(InspectorButtonStyle())
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

    private var centerBinding: Binding<CGPoint> {
        Binding(get: { spec.center }, set: { value in commit { $0.center = value } })
    }
}

/// A small 2D pad for placing the progressive-blur focus (docs/16 ED-16).
private struct FocusPad: View {
    @Binding var point: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(KadrFill.hover)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .position(
                        x: min(max(point.x, 0), 1) * size.width,
                        y: min(max(point.y, 0), 1) * size.height
                    )
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                point = CGPoint(
                    x: min(max(value.location.x / size.width, 0), 1),
                    y: min(max(value.location.y / size.height, 0), 1)
                )
            })
        }
        .accessibilityLabel("Focus position")
    }
}
