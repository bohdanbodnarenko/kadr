import AnnotationModel
import SwiftUI

/// Per-tool style controls (docs/03 §3).
///
/// Edits go to the style memory *and* to the current selection, which is what makes the
/// inspector feel like it belongs to whatever is on screen rather than to a mode.
struct EditorInspector: View {
    @Bindable var model: EditorDocumentModel

    private var tool: AnnotationTool {
        model.tool.annotation ?? .arrow
    }

    var body: some View {
        Form {
            Section(model.tool.title) {
                if tool != .crop, tool != .counter {
                    colorPicker
                    widthPicker
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
                    Button("Bring to Front") { model.bringSelectionToFront() }
                    Button("Send to Back") { model.sendSelectionToBack() }
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                }
            }

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

    private var colorPicker: some View {
        ColorPicker("Colour", selection: Binding(
            get: { Color(model.styleMemory.stroke(for: tool).color) },
            set: { newValue in
                var stroke = model.styleMemory.stroke(for: tool)
                stroke.color = AnnotationColor(newValue)
                model.styleMemory.remember(stroke, for: tool)
            }
        ))
    }

    private var widthPicker: some View {
        Picker("Width", selection: Binding(
            get: { model.styleMemory.stroke(for: tool).width },
            set: { newValue in
                var stroke = model.styleMemory.stroke(for: tool)
                stroke.width = newValue
                model.styleMemory.remember(stroke, for: tool)
            }
        )) {
            ForEach(StrokeStyle.widthPresets, id: \.self) { width in
                Text("\(Int(width)) pt").tag(width)
            }
        }
    }

    private var arrowOptions: some View {
        Picker("Head", selection: $model.styleMemory.lastArrowHead) {
            ForEach(ArrowHead.allCases, id: \.self) { head in
                Text(head.title).tag(head)
            }
        }
    }

    private var shapeOptions: some View {
        Toggle("Filled", isOn: Binding(
            get: { model.styleMemory.fill(for: .shape).color != nil },
            set: { isFilled in
                let colour = model.styleMemory.stroke(for: .shape).color.withAlpha(0.25)
                model.styleMemory.remember(FillStyle(color: isFilled ? colour : nil), for: .shape)
            }
        ))
    }

    private var redactionOptions: some View {
        Picker("Style", selection: Binding(
            get: {
                if case .pixelate = model.styleMemory.lastRedactionStyle {
                    return 1
                }
                return 0
            },
            set: { model.styleMemory.lastRedactionStyle = $0 == 1 ? .defaultPixelate : .defaultBlur }
        )) {
            Text("Blur").tag(0)
            Text("Pixelate").tag(1)
        }
        .pickerStyle(.segmented)
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
