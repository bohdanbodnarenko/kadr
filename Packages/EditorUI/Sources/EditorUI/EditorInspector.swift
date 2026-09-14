import AnnotationModel
import SwiftUI

/// Per-tool style controls (docs/03 §3, docs/14 UX-30).
///
/// Context first: armed tool or selection, then canvas chrome, then export. Advanced global
/// effects start collapsed and remember their disclosure state.
struct EditorInspector: View {
    @Bindable var model: EditorDocumentModel

    private var tool: AnnotationTool? {
        model.inspectedTool
    }

    var body: some View {
        Form {
            contextSection
            selectionSection
            canvasSection
            exportSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Context

    @ViewBuilder
    private var contextSection: some View {
        if model.tool == .sticker {
            Section("Sticker") {
                EmojiStickerPicker(selected: $model.stickerEmoji)
            }
        }

        if model.tool == .crop {
            EditorCropInspector(model: model)
        }

        if let tool, tool != .crop, tool != .image {
            Section(tool.title) {
                if tool == .text {
                    EditorTextInspector(model: model)
                } else {
                    toolStyleControls(for: tool)
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
        }

        if let image = model.selectedImage {
            imageSection(image)
        }

        if model.hasSubjectLift || model.subjectLiftError != nil {
            subjectLiftSection
        }
    }

    @ViewBuilder
    private func toolStyleControls(for tool: AnnotationTool) -> some View {
        if tool != .counter, tool != .redaction, tool != .spotlight {
            EditorSwatchStrip(
                selected: model.styleMemory.stroke(for: tool).color,
                onSelect: { model.applyColor($0) }
            )
            EditorWidthPresets(
                selected: model.styleMemory.stroke(for: tool).width,
                onSelect: { model.applyStrokeWidth($0) }
            )
            InspectorSlider(
                title: "Width",
                value: Binding(
                    get: { Double(model.styleMemory.stroke(for: tool).width) },
                    set: { model.applyStrokeWidth(CGFloat($0)) }
                ),
                range: Double(StrokeStyle.widthRange.lowerBound)
                    ... Double(StrokeStyle.widthRange.upperBound),
                format: .points,
                onEditingEnded: { model.endInspectorStyleEdit() }
            )
        }
    }

    // MARK: - Selection

    @ViewBuilder
    private var selectionSection: some View {
        if !model.selection.isEmpty {
            Section("Selection") {
                Button("Duplicate") { model.duplicateSelection() }
                Button("Delete", role: .destructive) { model.deleteSelection() }
            }
        }
    }

    // MARK: - Canvas / appearance

    @ViewBuilder
    private var canvasSection: some View {
        EditorStylePresetInspector(model: model)
        EditorBeautifyInspector(model: model)
        EditorCameraInspector(model: model)
        EditorBlurInspector(model: model)
        EditorWatermarkInspector(model: model)
        EditorResizeInspector(model: model)
    }

    // MARK: - Export

    private var exportSection: some View {
        EditorInspectorSection(title: "Export", key: "export", startsOpen: false) {
            Text("Copy and Save use the resize scale above.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Output")
                Spacer()
                Text("\(Int(model.exportPixelSize.width)) × \(Int(model.exportPixelSize.height)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func imageSection(_ image: ImageSpec) -> some View {
        Section("Image") {
            InspectorSlider(
                title: "Size",
                value: Binding(
                    get: { Double(image.scaleFactor) },
                    set: { factor in
                        model.updateSelectedImage { $0.scale(to: CGFloat(factor)) }
                    }
                ),
                range: 0.1 ... 4,
                format: .multiplier
            )
            InspectorSlider(
                title: "Opacity",
                value: Binding(
                    get: { image.opacity },
                    set: { value in model.updateSelectedImage { $0.opacity = value } }
                ),
                range: 0.1 ... 1,
                format: .percent
            )
            InspectorSlider(
                title: "Corners",
                value: Binding(
                    get: { Double(image.cornerRadius) },
                    set: { value in
                        model.updateSelectedImage { $0.cornerRadius = CGFloat(value) }
                    }
                ),
                range: 0 ... 40,
                format: .points
            )
            Toggle("Shadow", isOn: Binding(
                get: { image.hasShadow },
                set: { value in model.updateSelectedImage { $0.hasShadow = value } }
            ))
        }
    }

    private var subjectLiftSection: some View {
        Section("Background") {
            if let message = model.subjectLiftError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasSubjectLift {
                Picker("Fill", selection: Binding(
                    get: { model.subjectLiftBackground.color == nil },
                    set: { isTransparent in
                        model.setSubjectLiftBackground(isTransparent ? .transparent : .color(.white))
                    }
                )) {
                    Text("Transparent").tag(true)
                    Text("Colour").tag(false)
                }
                .pickerStyle(.segmented)

                if let colour = model.subjectLiftBackground.color {
                    ColorPicker("Colour", selection: Binding(
                        get: { Color(colour) },
                        set: { model.setSubjectLiftBackground(.color(AnnotationColor($0))) }
                    ))
                }
                Text("Transparent exports as PNG whatever the format setting says — "
                    + "JPEG has no alpha channel to put the cut-out in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var arrowOptions: some View {
        Picker("Head", selection: Binding(
            get: { model.styleMemory.lastArrowHead },
            set: { model.applyArrowHead($0) }
        )) {
            ForEach(ArrowHead.allCases, id: \.self) { head in
                Text(head.title).tag(head)
            }
        }
    }

    @ViewBuilder
    private var shapeOptions: some View {
        Picker("Shape", selection: Binding(
            get: { ShapeKind.Family(model.styleMemory.lastShapeKind) },
            set: { model.applyShapeKind($0.kind) }
        )) {
            ForEach(ShapeKind.Family.allCases) { family in
                Text(family.title).tag(family)
            }
        }
        .pickerStyle(.segmented)

        Toggle("Filled", isOn: Binding(
            get: { model.styleMemory.fill(for: .shape).color != nil },
            set: { isFilled in
                let colour = model.styleMemory.stroke(for: .shape).color
                    .withAlpha(model.styleMemory.lastFillOpacity)
                model.applyShapeFill(isFilled ? colour : nil)
            }
        ))
        if model.styleMemory.fill(for: .shape).color != nil {
            InspectorSlider(
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
        Picker("Style", selection: Binding(
            get: { style.kind },
            set: { model.applyRedactionStyle(style.withKind($0)) }
        )) {
            ForEach(RedactionKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)

        if style.kind != .erase {
            InspectorSlider(
                title: "Strength",
                value: Binding(
                    get: { Double(style.density) },
                    set: { model.applyRedactionStyle(style.withDensity(CGFloat($0))) }
                ),
                range: 0.15 ... 1,
                format: .percent
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
        InspectorSlider(
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
        InspectorSlider(
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
        Picker("Measure", selection: $model.styleMemory.lastMeasuresBox) {
            Text("Distance").tag(false)
            Text("Box").tag(true)
        }
        .pickerStyle(.segmented)

        Text(model.edgeCandidates.isEmpty
            ? "Drag to measure. Click an element to measure the box around it."
            : "Drag to measure — endpoints snap to the edges Kadr found. "
            + "Click an element to measure the box around it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
