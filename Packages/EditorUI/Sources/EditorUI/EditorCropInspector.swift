import AnnotationModel
import SwiftUI

/// The crop's ratio, canvas controls and the way out (docs/03 §3, docs/09 U1.8).
///
/// The handles live on the canvas; what belongs here is the state a drag cannot express —
/// which ratio to hold, whether the crop may leave the image at all, and when the user is
/// finished.
///
/// "Crop is a mode until **Done**", says docs/03 §3, and there was no Done. The only ways
/// out were pressing Escape or picking another tool, neither of which is written anywhere
/// on screen — so the mode had a visible entrance and an invisible exit, and somebody who
/// had cropped what they wanted was left holding handles with nothing saying the job was
/// finished.
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
            }

            HStack {
                Button("Done") { model.selectTool(.select) }
                    .keyboardShortcut(.defaultAction)
                    .help("Finish cropping (Return). The crop stays editable — reopen Crop to change it.")
                Spacer()
                Button("Reset") { model.clearCrop() }
                    .disabled(crop == nil)
                    .help("Put the crop back to the whole capture")
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
