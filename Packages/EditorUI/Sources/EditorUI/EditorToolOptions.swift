import AnnotationModel
import ControlKit
import SwiftUI

/// The controls one annotation tool has (docs/03 §3).
///
/// Laid into the Style pane's group as rows, so every tool uses the same rhythm: colour,
/// then stroke, then whatever is particular to the tool.
struct EditorToolOptions: View {
    @Bindable var model: EditorDocumentModel
    let tool: AnnotationTool

    var body: some View {
        if tool == .text {
            EditorTextInspector(model: model)
        } else {
            if tool != .counter, tool != .redaction, tool != .spotlight {
                strokeControls
            }
            switch tool {
            case .arrow: arrowOptions
            case .shape: shapeOptions
            case .redaction: redactionOptions
            case .spotlight: spotlightOptions
            case .measure: measureOptions
            case .counter: EditorCounterInspector(model: model)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var strokeControls: some View {
        let stroke = model.styleMemory.stroke(for: tool)
        InspectorStackedRow("Color") {
            EditorSwatchStrip(selected: stroke.color, onSelect: { model.applyColor($0) })
        }
        InspectorRow("Stroke") {
            EditorWidthPresets(selected: stroke.width, onSelect: { model.applyStrokeWidth($0) })
        }
        KadrSlider(
            title: "Width",
            value: Binding(
                get: { Double(model.styleMemory.stroke(for: tool).width) },
                set: { model.applyStrokeWidth(CGFloat($0)) }
            ),
            range: Double(StrokeStyle.widthRange.lowerBound) ... Double(StrokeStyle.widthRange.upperBound),
            format: .points,
            onEditingEnded: { model.endInspectorStyleEdit() }
        )
    }

    @ViewBuilder
    private var arrowOptions: some View {
        InspectorRow("End") {
            Picker("End", selection: Binding(
                get: { model.styleMemory.lastArrowHead },
                set: { model.applyArrowHead($0) }
            )) {
                ForEach(ArrowHead.allCases, id: \.self) { head in
                    Text(head.title).tag(head)
                }
            }
            .inspectorMenuPicker()
        }
        InspectorRow("Start") {
            Picker("Start", selection: Binding(
                get: { model.styleMemory.lastStartArrowHead },
                set: { model.applyStartArrowHead($0) }
            )) {
                Text("None").tag(ArrowHead?.none)
                ForEach(ArrowHead.allCases, id: \.self) { head in
                    Text(head.title).tag(Optional(head))
                }
            }
            .inspectorMenuPicker()
        }
    }

    @ViewBuilder
    private var shapeOptions: some View {
        InspectorSegmented(
            Array(ShapeKind.Family.allCases),
            selection: Binding(
                get: { ShapeKind.Family(model.styleMemory.lastShapeKind) },
                set: { model.applyShapeKind($0.kind) }
            ),
            title: \.title
        )

        InspectorToggleRow("Fill", isOn: Binding(
            get: { model.styleMemory.fill(for: .shape).color != nil },
            set: { isFilled in
                let colour = model.styleMemory.stroke(for: .shape).color
                    .withAlpha(model.styleMemory.lastFillOpacity)
                model.applyShapeFill(isFilled ? colour : nil)
            }
        ))

        if model.styleMemory.fill(for: .shape).color != nil {
            KadrSlider(
                title: "Fill opacity",
                value: Binding(
                    get: { model.styleMemory.lastFillOpacity },
                    set: { model.applyFillOpacity($0) }
                ),
                range: 0 ... 1,
                format: .percent,
                onEditingEnded: { model.endInspectorStyleEdit() }
            )
        }
    }

    @ViewBuilder
    private var redactionOptions: some View {
        let style = inspectedRedactionStyle
        InspectorSegmented(
            Array(RedactionKind.allCases),
            selection: Binding(
                get: { style.kind },
                set: { model.applyRedactionStyle(style.withKind($0)) }
            ),
            title: \.title
        )

        if style.kind != .erase {
            KadrSlider(
                title: "Strength",
                value: Binding(
                    get: { Double(style.density) },
                    set: { model.applyRedactionStyleLive(style.withDensity(CGFloat($0))) }
                ),
                range: 0.15 ... 1,
                format: .percent,
                onEditingEnded: { model.endInspectorStyleEdit() }
            )
        }
    }

    private var inspectedRedactionStyle: RedactionStyle {
        if let id = model.selection.first, case let .redaction(spec)? = model.document.command(id) {
            return spec.style
        }
        return model.styleMemory.lastRedactionStyle
    }

    @ViewBuilder
    private var spotlightOptions: some View {
        KadrSlider(
            title: "Dim",
            value: Binding(
                get: { Double(inspectedSpotlight.dimOpacity) },
                set: { model.applySpotlightDimOpacity(CGFloat($0)) }
            ),
            range: Double(SpotlightSpec.dimOpacityRange.lowerBound)
                ... Double(SpotlightSpec.dimOpacityRange.upperBound),
            format: .percent,
            onEditingEnded: { model.endInspectorStyleEdit() }
        )
        KadrSlider(
            title: "Corners",
            value: Binding(
                get: { Double(inspectedSpotlight.cornerRadius) },
                set: { model.applySpotlightCornerRadius(CGFloat($0)) }
            ),
            range: Double(SpotlightSpec.cornerRadiusRange.lowerBound)
                ... Double(SpotlightSpec.cornerRadiusRange.upperBound),
            format: .points,
            onEditingEnded: { model.endInspectorStyleEdit() }
        )
    }

    private var inspectedSpotlight: SpotlightSpec {
        if let id = model.selection.first, case let .spotlight(spec)? = model.document.command(id) {
            return spec
        }
        return SpotlightSpec(
            rect: .zero,
            dimOpacity: model.styleMemory.lastSpotlightDimOpacity,
            cornerRadius: model.styleMemory.lastSpotlightCornerRadius
        )
    }

    @ViewBuilder
    private var measureOptions: some View {
        InspectorSegmented(
            [false, true],
            selection: $model.styleMemory.lastMeasuresBox,
            title: { $0 ? "Box" : "Distance" }
        )

        InspectorNote(model.edgeCandidates.isEmpty
            ? "Drag to measure. Click an element to measure the box around it."
            : "Drag to measure — endpoints snap to the edges Kadr found. "
            + "Click an element to measure the box around it.")
    }
}
