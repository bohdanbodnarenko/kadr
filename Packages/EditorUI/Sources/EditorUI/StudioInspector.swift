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
    /// Read by `StudioInspector+Speech.swift`: a large removal has to be confirmed twice,
    /// and the confirmation lives in the speech half while the state belongs to the view.
    @State var largeRemovalArmed = false

    var body: some View {
        Form {
            selectedClipSection
            selectedZoomSection
            shapeSection
            canvasSection
            cropSection
            cameraSection
            overlaySection
            speechSection
            audioSection
        }
        .formStyle(.grouped)
        .task {
            await model.refreshSpeechStatus()
            model.warmUpSpeech()
        }
    }

    // MARK: - The selected clip

    @ViewBuilder
    private var selectedClipSection: some View {
        if let clip = selectedClip {
            StudioInspectorSection(title: "Clip", key: "clip") {
                InspectorSlider(
                    title: "Speed",
                    value: Binding(
                        get: { clip.speed },
                        set: { value in model.setSpeed(value, for: clip.id) }
                    ),
                    range: Clip.minimumSpeed ... Clip.maximumSpeed,
                    format: .multiplier
                )
                Text("Audio stays in sync. Faster than 8× is unreadable, so that is the cap.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Split at playhead") { model.splitAtPlayhead() }
                    .controlSize(.small)
                Button("Delete clip") { model.removeClipAtPlayhead() }
                    .controlSize(.small)
                    .disabled(model.edit.clips.clips.count < 2)
            }
        }
    }

    private var selectedClip: Clip? {
        if let id = model.selectedClip {
            return model.edit.clips.clips.first(where: { $0.id == id })
        }
        guard let index = model.clipIndex(at: model.playhead) else { return nil }
        return model.edit.clips.clips[index]
    }

    // MARK: - Shape

    private var shapeSection: some View {
        StudioInspectorSection(title: "Shape", key: "shape") {
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
        StudioInspectorSection(title: "Crop", key: "crop", startsOpen: false) {
            if model.canTrimNotch {
                Button("Remove the notch strip") { model.trimNotchStrip() }
                Text("This display has a notch, so the top of the recording has a bite out "
                    + "of it. This crops that strip away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
            Button("Crop on preview") { model.beginCrop() }
                .help("Drag the crop on the picture rather than with these sliders")
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
        StudioInspectorSection(title: "Camera", key: "camera") {
            Toggle("Show the camera", isOn: Binding(
                get: { model.edit.camera.isVisible },
                set: { value in model.change { $0.camera.isVisible = value } }
            ))
            .disabled(!model.manifest.hasCamera)
            if model.manifest.hasCamera {
                Text("Drag the bubble to place it, or drag a corner to resize.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.manifest.hasCamera {
                Text("This recording has no camera track.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Fill the frame", isOn: Binding(
                get: { model.edit.camera.isFullscreen },
                set: { value in model.change { $0.camera.isFullscreen = value } }
            ))
            .help("Talking-head mode: the camera fills the export.")
            Picker("Corner", selection: Binding(
                get: { model.edit.camera.placement },
                set: { value in model.snapCamera(to: value) }
            )) {
                ForEach(BubblePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(model.edit.camera.isFullscreen)
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
            .disabled(model.edit.camera.isFullscreen)
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

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
