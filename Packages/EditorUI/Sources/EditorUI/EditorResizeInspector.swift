import SwiftUI

/// Change output resolution without leaving the editor (docs/03 §3 P2, CleanShot 4.7).
///
/// The canvas stays at capture resolution so annotations stay sharp; Copy and Save
/// write the scaled bitmap. Upscaling is refused — it cannot add detail.
struct EditorResizeInspector: View {
    @Bindable var model: EditorDocumentModel

    var body: some View {
        EditorInspectorSection(title: "Resize", key: "resize", startsOpen: false) {
            Text(sizeLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            InspectorSlider(
                title: "Width",
                value: Binding(
                    get: { Double(model.exportPixelSize.width) },
                    set: { model.setExportPixelWidth(CGFloat($0)) }
                ),
                range: Double(minimumWidth) ... Double(max(minimumWidth, model.nativeExportPixelSize.width)),
                format: .points
            )

            HStack(spacing: 8) {
                Button("100%") { model.resetExportScale() }
                    .disabled(abs(model.exportScale - 1) < 0.001)
                Button("50%") { model.setExportScale(0.5) }
                    .disabled(abs(model.exportScale - 0.5) < 0.001)
                if model.canScaleExportToOneToOne {
                    Button("1×") { model.scaleExportToOneToOne() }
                        .disabled(abs(model.exportScale - oneToOneScale) < 0.001)
                }
            }
            .controlSize(.small)
            .help("Scale the exported image. The canvas stays at capture resolution.")
        }
    }

    private var minimumWidth: CGFloat {
        max(1, (model.nativeExportPixelSize.width * 0.25).rounded())
    }

    private var oneToOneScale: CGFloat {
        1 / max(model.document.baseImage.scale, 1)
    }

    private var sizeLabel: String {
        let size = model.exportPixelSize
        let native = model.nativeExportPixelSize
        if abs(model.exportScale - 1) < 0.001 {
            return "\(Int(size.width)) × \(Int(size.height)) px"
        }
        return "\(Int(size.width)) × \(Int(size.height)) px  (from \(Int(native.width)) × \(Int(native.height)))"
    }
}
