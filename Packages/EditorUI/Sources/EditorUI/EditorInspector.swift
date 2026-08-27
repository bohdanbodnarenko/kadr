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
                default: EmptyView()
                }
            }

            if !model.selection.isEmpty {
                Section("Selection") {
                    Button("Bring to Front") { model.bringSelectionToFront() }
                    Button("Send to Back") { model.sendSelectionToBack() }
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                }
            }
        }
        .formStyle(.grouped)
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

private extension Color {
    init(_ colour: AnnotationColor) {
        self.init(.sRGB, red: colour.red, green: colour.green, blue: colour.blue, opacity: colour.alpha)
    }
}

private extension AnnotationColor {
    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .red
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }
}
