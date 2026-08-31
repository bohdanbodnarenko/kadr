import AnnotationModel
import SwiftUI

/// Per-tool style controls (docs/03 §3).
///
/// Edits go to the style memory *and* to the current selection, which is what makes the
/// inspector feel like it belongs to whatever is on screen rather than to a mode.
struct EditorInspector: View {
    @Bindable var model: EditorDocumentModel

    private var tool: AnnotationTool {
        model.inspectedTool ?? .arrow
    }

    var body: some View {
        Form {
            Section(tool.title) {
                if tool != .crop, tool != .counter, tool != .redaction {
                    EditorSwatchStrip(
                        selected: model.styleMemory.stroke(for: tool).color,
                        onSelect: { model.applyColor($0) }
                    )
                    EditorStrokeWidthStrip(
                        selected: model.styleMemory.stroke(for: tool).width,
                        onSelect: { model.applyStrokeWidth($0) }
                    )
                }
                switch tool {
                case .arrow: arrowOptions
                case .shape: shapeOptions
                case .redaction: redactionOptions
                case .text: textOptions
                case .measure: measureOptions
                default: EmptyView()
                }
            }

            if model.selectedImage != nil {
                imageSection
            }

            if model.hasSubjectLift || model.subjectLiftError != nil {
                subjectLiftSection
            }

            if !model.selection.isEmpty {
                Section("Selection") {
                    Button("Duplicate") { model.duplicateSelection() }
                    Button("Bring to Front") { model.bringSelectionToFront() }
                    Button("Bring Forward") { model.bringSelectionForward() }
                        .keyboardShortcut("]", modifiers: .command)
                    Button("Send Backward") { model.sendSelectionBackward() }
                        .keyboardShortcut("[", modifiers: .command)
                    Button("Send to Back") { model.sendSelectionToBack() }
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                }
            }

            if model.tool == .crop {
                EditorCropInspector(model: model)
            }

            EditorStylePresetInspector(model: model)
            EditorBeautifyInspector(model: model)
            EditorCameraInspector(model: model)
            EditorBlurInspector(model: model)
            EditorWatermarkInspector(model: model)
        }
        .formStyle(.grouped)
    }

    /// The controls for a dropped-in image (docs/06 M24).
    ///
    /// Size, opacity, corners and shadow — the four things a composition actually needs,
    /// and no more: an inserted screenshot is being arranged, not retouched.
    @ViewBuilder
    private var imageSection: some View {
        if let image = model.selectedImage {
            Section("Image") {
                LabeledContent("Size") {
                    Slider(
                        value: Binding(
                            get: { Double(image.scaleFactor) },
                            set: { factor in
                                model.updateSelectedImage { $0.scale(to: CGFloat(factor)) }
                            }
                        ),
                        in: 0.1 ... 4
                    )
                }
                LabeledContent("Opacity") {
                    Slider(
                        value: Binding(
                            get: { image.opacity },
                            set: { value in model.updateSelectedImage { $0.opacity = value } }
                        ),
                        in: 0.1 ... 1
                    )
                }
                LabeledContent("Corners") {
                    Slider(
                        value: Binding(
                            get: { Double(image.cornerRadius) },
                            set: { value in
                                model.updateSelectedImage { $0.cornerRadius = CGFloat(value) }
                            }
                        ),
                        in: 0 ... 40
                    )
                }
                Toggle("Shadow", isOn: Binding(
                    get: { image.hasShadow },
                    set: { value in model.updateSelectedImage { $0.hasShadow = value } }
                ))
            }
        }
    }

    /// What fills the space the background used to occupy (docs/06 M23).
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
                let colour = model.styleMemory.stroke(for: .shape).color.withAlpha(0.25)
                model.applyShapeFill(isFilled ? colour : nil)
            }
        ))
    }

    @ViewBuilder
    private var redactionOptions: some View {
        let style = inspectedRedactionStyle
        Picker("Style", selection: Binding(
            get: { style.isPixelate },
            set: { model.applyRedactionStyle(style.togglingKind(pixelate: $0)) }
        )) {
            Text("Blur").tag(false)
            Text("Pixelate").tag(true)
        }
        .pickerStyle(.segmented)

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

    /// The redaction the inspector is editing: the selection's, or the armed tool's memory.
    private var inspectedRedactionStyle: RedactionStyle {
        if let id = model.selection.first, case let .redaction(spec)? = model.document.command(id) {
            return spec.style
        }
        return model.styleMemory.lastRedactionStyle
    }

    /// The measure tool's one choice, plus what the tool actually does (docs/06 M21).
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

    private var textOptions: some View {
        Picker("Preset", selection: Binding(
            get: { TextStyle.presets.firstIndex { $0.style == model.styleMemory.lastTextStyle } ?? 0 },
            set: { model.styleMemory.lastTextStyle = TextStyle.presets[$0].style }
        )) {
            ForEach(Array(TextStyle.presets.enumerated()), id: \.offset) { index, preset in
                Text(preset.name).tag(index)
            }
        }
    }
}
