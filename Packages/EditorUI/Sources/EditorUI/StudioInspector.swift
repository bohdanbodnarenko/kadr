import Foundation
import StudioSession
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
            cropSection
            cameraSection
            overlaySection
            speechSection
            presetSection
        }
        .formStyle(.grouped)
        .task { await model.refreshSpeechStatus() }
    }

    // MARK: - Speech

    /// Removing filler words and long pauses (docs/09 U3.6).
    ///
    /// The download is a separate control from the tidy-up, deliberately. Merging them
    /// would mean pressing "tidy up" could start a several-hundred-megabyte fetch, which is
    /// not what that button says it does — and on a machine with no network it would be a
    /// button that hangs instead of one that explains.
    private var speechSection: some View {
        Section("Speech") {
            switch model.speechStatus {
            case .installed, .notApplicable, .none:
                tidyControl
            case .available:
                Text("Removing filler words needs the language model for your language, which "
                    + "this Mac does not have yet. Everything else in the studio works without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                installControl
            case .downloading:
                installControl
            case .unsupported:
                Text("macOS has no speech model for your language, so filler words cannot be "
                    + "found automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tidyControl: some View {
        if model.isTranscribing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Listening to the recording…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Remove filler words and long pauses") {
                Task { await model.tidySpeech() }
            }
            Text("Cuts \u{201C}um\u{201D} and pauses over a second. They become clip boundaries, "
                + "so one undo puts them all back and the recording is never altered.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installControl: some View {
        if let progress = model.installProgress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Button("Cancel download") { model.cancelSpeechModelInstall() }
                    .controlSize(.small)
            }
        } else {
            Button("Download the language model…") { model.installSpeechModel() }
            Text("Downloads Apple's on-device model. It is the only thing in the studio that "
                + "uses the network, it is optional, and your recording is never uploaded — "
                + "the model comes here, the audio stays.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

    // MARK: - Crop

    /// An arbitrary rectangle in the recording, applied before the aspect reframe
    /// (docs/10 R3.5).
    private var cropSection: some View {
        Section("Crop") {
            LabeledContent("Left") {
                Slider(value: cropX, in: 0 ... 0.9)
            }
            LabeledContent("Bottom") {
                Slider(value: cropY, in: 0 ... 0.9)
            }
            LabeledContent("Width") {
                Slider(value: cropWidth, in: 0.1 ... 1)
            }
            LabeledContent("Height") {
                Slider(value: cropHeight, in: 0.1 ... 1)
            }
            Button("Reset crop") { model.change { $0.cropRect = nil } }
                .disabled(model.edit.cropRect == nil)
        }
    }

    private var normalizedCrop: CGRect {
        model.edit.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private var cropX: Binding<Double> {
        cropEdge(gesture: "crop.x", get: { $0.origin.x }, set: { $0.origin.x = $1 })
    }

    private var cropY: Binding<Double> {
        cropEdge(gesture: "crop.y", get: { $0.origin.y }, set: { $0.origin.y = $1 })
    }

    private var cropWidth: Binding<Double> {
        cropEdge(gesture: "crop.width", get: { $0.width }, set: { $0.size.width = $1 })
    }

    private var cropHeight: Binding<Double> {
        cropEdge(gesture: "crop.height", get: { $0.height }, set: { $0.size.height = $1 })
    }

    /// - Parameter gesture: names this slider, so one drag of it is one undo step and
    ///   dragging a different edge afterwards starts another (docs/11 S2).
    private func cropEdge(
        gesture: String,
        get: @escaping (CGRect) -> CGFloat,
        set: @escaping (inout CGRect, Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { Double(get(normalizedCrop)) },
            set: { value in
                var rect = normalizedCrop
                set(&rect, value)
                let x = min(max(rect.origin.x, 0), 0.95)
                let y = min(max(rect.origin.y, 0), 0.95)
                let width = min(max(rect.width, 0.05), 1 - x)
                let height = min(max(rect.height, 0.05), 1 - y)
                let next = CGRect(x: x, y: y, width: width, height: height)
                model.change(coalescingAs: gesture) {
                    $0.cropRect = next == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : next
                }
            }
        )
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
                    set: { value in model.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = value } }
                ), in: 0.08 ... 0.6)
            }
            LabeledContent("Roundness") {
                Slider(value: Binding(
                    get: { model.edit.camera.roundness },
                    set: { value in model.change(coalescingAs: "camera.roundness") { $0.camera.roundness = value } }
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
