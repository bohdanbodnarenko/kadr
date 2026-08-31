import AppKit
import Foundation
import Shared
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
    @State private var largeRemovalArmed = false

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
        .task {
            await model.refreshSpeechStatus()
            model.warmUpSpeech()
        }
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
            if !model.supportedLocales.isEmpty {
                Picker("Language", selection: Bindable(model).speechLocaleIdentifier) {
                    ForEach(model.supportedLocales, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                            .tag(identifier)
                    }
                }
                .onChange(of: model.speechLocaleIdentifier) {
                    Task { await model.refreshSpeechStatus() }
                }
            }
            switch model.speechStatus {
            case .installed, .none:
                tidyControl
            case .notApplicable:
                if model.dictationSettingsNeeded {
                    Text("Removing filler words needs on-device dictation for this language. "
                        + "Turn it on in System Settings ▸ Keyboard ▸ Dictation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Dictation Settings") {
                        if let url = SpeechDictationSettings.url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    tidyControl
                }
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
            if !model.pendingCuts.isEmpty {
                cutReview
            }
            if model.transcript != nil {
                Toggle("Burn in captions", isOn: Binding(
                    get: { model.edit.showsCaptions },
                    set: { value in model.change { $0.showsCaptions = value } }
                ))
            }
        }
        .onChange(of: model.pendingCuts.map(\.id)) {
            largeRemovalArmed = false
        }
    }

    @ViewBuilder
    private var tidyControl: some View {
        if model.isTranscribing {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = model.transcriptionProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Listening to the recording…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelTidySpeech() }
                    .controlSize(.small)
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
    private var cutReview: some View {
        Text("Proposed cuts")
            .font(.callout.weight(.semibold))
        ForEach(model.pendingCuts) { cut in
            HStack {
                Toggle(isOn: Binding(
                    get: { model.selectedCutIDs.contains(cut.id) },
                    set: { _ in model.toggleCut(cut.id) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cut.label)
                        Text(Self.clock(cut.start) + " · " + cut.reason.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Preview") { model.seekToCut(cut) }
                    .controlSize(.small)
            }
        }
        HStack {
            Button(largeRemovalArmed ? "Apply anyway" : "Apply selected") {
                if model.requiresCutConfirmation, !largeRemovalArmed {
                    largeRemovalArmed = true
                    return
                }
                model.applyPendingCuts(confirmingLargeRemoval: largeRemovalArmed)
                largeRemovalArmed = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                largeRemovalArmed = false
                model.discardPendingCuts()
            }
        }
        if model.requiresCutConfirmation {
            Text(largeRemovalArmed
                ? "This would remove more than 40% of the recording. Press Apply anyway to confirm."
                : "This would remove more than 40% of the recording. Press Apply again to confirm.")
                .font(.callout)
                .foregroundStyle(.orange)
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
                InspectorSlider(
                    title: "Magnification",
                    value: Binding(
                        get: { cue.magnification },
                        set: { value in model.updateZoom(id) { $0.magnification = value } }
                    ),
                    range: 1 ... ZoomCue.maximumMagnification,
                    format: .multiplier
                )
                InspectorSlider(
                    title: "Hold",
                    value: Binding(
                        get: { cue.duration },
                        set: { value in model.updateZoom(id) { $0.duration = value } }
                    ),
                    range: 0.2 ... max(model.edit.duration, 1),
                    format: .seconds
                )
                InspectorSlider(
                    title: "Move",
                    value: Binding(
                        get: { cue.transitionDuration },
                        set: { value in model.updateZoom(id) { $0.transitionDuration = value } }
                    ),
                    range: 0.1 ... 2,
                    format: .seconds
                )
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
            InspectorSlider(title: "Left", value: cropX, range: 0 ... 0.9, format: .percent)
            // "Top", not "Bottom" (docs/11 S2). `cropRect` is normalised source space and
            // the renderer treats it as top-left throughout — `pixelCrop` hands the plan a
            // rect it offsets by `crop.minY` and the composer flips once at the very end.
            // So raising this slider moves the crop *down*, and the label said the opposite.
            InspectorSlider(title: "Top", value: cropY, range: 0 ... 0.9, format: .percent)
            InspectorSlider(title: "Width", value: cropWidth, range: 0.1 ... 1, format: .percent)
            InspectorSlider(title: "Height", value: cropHeight, range: 0.1 ... 1, format: .percent)
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
            InspectorSlider(
                title: "Size",
                value: Binding(
                    get: { model.edit.camera.sizeFraction },
                    set: { value in
                        model.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = value }
                    }
                ),
                range: 0.08 ... 0.6,
                format: .percent
            )
            InspectorSlider(
                title: "Roundness",
                value: Binding(
                    get: { model.edit.camera.roundness },
                    set: { value in
                        model.change(coalescingAs: "camera.roundness") { $0.camera.roundness = value }
                    }
                ),
                range: 0 ... 1,
                format: .percent
            )
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

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
