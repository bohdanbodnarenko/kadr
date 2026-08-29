import Foundation
import StudioCore
import SwiftUI

/// The studio's controls (docs/09 U3.3–U3.5).
///
/// Grouped by what the user is deciding rather than by which type holds the value: the
/// shape of the output, what the camera does, what is drawn on top. A form organised by the
/// model's structure makes somebody learn the model to find a setting.
@MainActor
struct StudioInspector: View {
    let model: StudioDocumentModel

    var body: some View {
        Form {
            selectedZoomSection
            shapeSection
            cameraSection
            overlaySection
            presetSection
        }
        .formStyle(.grouped)
    }

    // MARK: - The selected zoom

    @ViewBuilder
    private var selectedZoomSection: some View {
        if let id = model.selectedZoom, let cue = model.edit.zooms.first(where: { $0.id == id }) {
            Section("Zoom") {
                LabeledContent("Magnification") {
                    Slider(
                        value: Binding(
                            get: { cue.magnification },
                            set: { value in model.updateZoom(id) { $0.magnification = value } }
                        ),
                        in: 1 ... ZoomCue.maximumMagnification
                    )
                }
                LabeledContent("Hold") {
                    Slider(
                        value: Binding(
                            get: { cue.duration },
                            set: { value in model.updateZoom(id) { $0.duration = value } }
                        ),
                        in: 0.2 ... max(model.edit.duration, 1)
                    )
                }
                LabeledContent("Move") {
                    Slider(
                        value: Binding(
                            get: { cue.transitionDuration },
                            set: { value in model.updateZoom(id) { $0.transitionDuration = value } }
                        ),
                        in: 0.1 ... 2
                    )
                }
                Button("Remove zoom", role: .destructive) { model.removeSelectedZoom() }
            }
        }
    }

    // MARK: - Shape

    private var shapeSection: some View {
        Section("Shape") {
            Picker("Aspect", selection: Binding(
                get: { model.edit.reframe.aspect },
                set: { value in model.change { $0.reframe.aspect = value } }
            )) {
                ForEach(ReframeAspect.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Fit", selection: Binding(
                get: { model.edit.reframe.fill },
                set: { value in model.change { $0.reframe.fill = value } }
            )) {
                ForEach(ReframeFill.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(model.edit.reframe.aspect == .original)
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section("Camera") {
            Toggle("Show the camera", isOn: Binding(
                get: { model.edit.camera.isVisible },
                set: { value in model.change { $0.camera.isVisible = value } }
            ))
            .disabled(!model.manifest.hasCamera)
            if !model.manifest.hasCamera {
                Text("This recording has no camera track.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Corner", selection: Binding(
                get: { model.edit.camera.placement },
                set: { value in model.change { $0.camera.placement = value } }
            )) {
                ForEach(BubblePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Size") {
                Slider(value: Binding(
                    get: { model.edit.camera.sizeFraction },
                    set: { value in model.change { $0.camera.sizeFraction = value } }
                ), in: 0.08 ... 0.6)
            }
            LabeledContent("Roundness") {
                Slider(value: Binding(
                    get: { model.edit.camera.roundness },
                    set: { value in model.change { $0.camera.roundness = value } }
                ), in: 0 ... 1)
            }
        }
        .disabled(!model.manifest.hasCamera)
    }

    // MARK: - Overlays

    private var overlaySection: some View {
        Section("On top") {
            Toggle("Draw the pointer", isOn: Binding(
                get: { model.edit.showsCursor },
                set: { value in model.change { $0.showsCursor = value } }
            ))
            .disabled(model.manifest.hasBakedCursor)
            if model.manifest.hasBakedCursor {
                Text("This recording already has the pointer in it. Record without it to have "
                    + "the studio draw a smooth one instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Ripple on clicks", isOn: Binding(
                get: { model.edit.showsClicks },
                set: { value in model.change { $0.showsClicks = value } }
            ))
            Toggle("Caption shortcuts", isOn: Binding(
                get: { model.edit.showsKeystrokes },
                set: { value in model.change { $0.showsKeystrokes = value } }
            ))
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section("Presets") {
            ForEach(StudioPreset.builtIn) { preset in
                Button(preset.name) { model.apply(preset) }
            }
            Text("A preset changes the look. It never moves a cut or a zoom.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
