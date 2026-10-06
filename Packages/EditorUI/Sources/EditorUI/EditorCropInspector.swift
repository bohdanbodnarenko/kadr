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
        InspectorGroup("Crop") {
            InspectorRow("Ratio") {
                Picker(String(localized: "Ratio", bundle: .module), selection: aspectBinding) {
                    ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .inspectorMenuPicker()
            }

            InspectorToggleRow("Allow the canvas to grow", isOn: expandBinding)
                .help(Text(
                    "Lets the crop extend past the capture, adding blank space rather than cutting.",
                    bundle: .module
                ))

            if crop != nil {
                // The working rect, not the stored one: it follows a handle drag live.
                InspectorNote(size(of: model.cropWorkingRect))
            }

            // Return is bound on the canvas crop bar, which is on screen whenever this is.
            HStack(spacing: 8) {
                Button(String(localized: "Reset", bundle: .module)) { model.clearCrop() }
                    .buttonStyle(InspectorButtonStyle())
                    .disabled(crop == nil)
                    .help(Text("Put the crop back to the whole capture", bundle: .module))
                Button(String(localized: "Done", bundle: .module)) { model.selectTool(.select) }
                    .buttonStyle(InspectorButtonStyle(isProminent: true))
                    .help(Text(
                        "Finish cropping (Return). The crop stays editable — reopen Crop to change it.",
                        bundle: .module
                    ))
            }
        }
    }

    private func size(of rect: CGRect) -> String {
        let points = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt"
        let scale = model.document.baseImage.scale
        guard scale > 1 else { return points }
        let pixels = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded())) px"
        return "\(points)  ·  \(pixels)"
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
