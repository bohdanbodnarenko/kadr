import AnnotationModel
import SwiftUI

/// The crop's ratio and canvas controls (docs/03 §3, docs/09 U1.8).
///
/// The handles live on the canvas; what belongs here is the state a drag cannot express —
/// which ratio to hold, and whether the crop may leave the image at all.
struct EditorCropInspector: View {
    @Bindable var model: EditorDocumentModel

    private var crop: CropSpec? {
        model.document.crop
    }

    var body: some View {
        Section("Crop") {
            Picker("Ratio", selection: aspectBinding) {
                ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            Toggle("Allow the canvas to grow", isOn: expandBinding)
                .help("Lets the crop extend past the capture, adding blank space rather than cutting.")

            if let crop {
                Text(size(of: crop))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset") { model.clearCrop() }
            }
        }
    }

    private func size(of crop: CropSpec) -> String {
        "\(Int(crop.rect.width.rounded())) × \(Int(crop.rect.height.rounded())) pt"
    }

    private var aspectBinding: Binding<CropAspectPreset> {
        Binding(
            get: { model.cropAspect },
            set: { preset in model.applyCropAspect(preset) }
        )
    }

    private var expandBinding: Binding<Bool> {
        Binding(
            get: { crop?.canExpandCanvas ?? false },
            set: { allowed in model.setCropCanExpandCanvas(allowed) }
        )
    }
}
