import ControlKit
import Foundation
import StudioSession
import SwiftUI

/// The shape of the picture: saved looks, aspect, crop and the camera bubble (docs/09 U3.4).
@MainActor
extension StudioInspector {
    // MARK: - Looks

    /// The preset row, at the top of the pane whose settings it saves.
    ///
    /// It used to be pinned above the inspector as a bar of its own, which made two toolbars
    /// stacked over one column and left the name of the current look nowhere near the
    /// controls that change it.
    var lookSection: some View {
        Section {
            StudioPresetBar(model: model)
        } header: {
            Text("Look", bundle: .module)
        } footer: {
            Text(
                "A look is the canvas, camera, pointer and overlays. Cuts and zooms are never part of one.",
                bundle: .module
            )
        }
    }

    // MARK: - Shape

    var shapeSection: some View {
        Section {
            Picker(String(localized: "Aspect", bundle: .module), selection: Binding(
                get: { model.edit.reframe.aspect },
                set: { value in model.change { $0.reframe.aspect = value } }
            )) {
                ForEach(ReframeAspect.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(String(localized: "Fit", bundle: .module), selection: Binding(
                get: { model.edit.reframe.fill },
                set: { value in model.change { $0.reframe.fill = value } }
            )) {
                ForEach(ReframeFill.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(model.edit.reframe.aspect == .original)
        } header: {
            Text("Shape", bundle: .module)
        } footer: {
            if model.edit.reframe.aspect == .original {
                Text(
                    "The recording's own proportions. Pick an aspect to fit it to a square or a portrait frame.",
                    bundle: .module
                )
            }
        }
    }

    // MARK: - Crop

    /// An arbitrary rectangle in the recording, applied before the aspect reframe
    /// (docs/10 R3.5).
    ///
    /// Dragging on the picture is the control; the numbers are behind a disclosure for the
    /// times a crop has to match an exact figure. Four sliders as the front door made the
    /// common case — "take a bit off the left" — into arithmetic.
    var cropSection: some View {
        Section {
            Button(String(localized: "Crop on Preview…", bundle: .module)) { model.beginCrop() }
            if model.canTrimNotch {
                Button(String(localized: "Remove Notch Strip", bundle: .module)) { model.trimNotchStrip() }
            }
            DisclosureGroup("Adjust Numerically") {
                KadrSlider(title: "Left", value: cropX, range: 0 ... 0.9, format: .percent)
                // "Top", not "Bottom" (docs/11 S2). `cropRect` is normalised source space and
                // the renderer treats it as top-left throughout — `pixelCrop` hands the plan a
                // rect it offsets by `crop.minY` and the composer flips once at the very end.
                // So raising this slider moves the crop *down*, and the label said the opposite.
                KadrSlider(title: "Top", value: cropY, range: 0 ... 0.9, format: .percent)
                KadrSlider(title: "Width", value: cropWidth, range: 0.1 ... 1, format: .percent)
                KadrSlider(title: "Height", value: cropHeight, range: 0.1 ... 1, format: .percent)
            }
            if model.edit.cropRect != nil {
                Button(String(localized: "Reset Crop", bundle: .module)) { model.change { $0.cropRect = nil } }
            }
        } header: {
            Text("Crop", bundle: .module)
        } footer: {
            if model.canTrimNotch {
                Text("This display has a notch, so the recording has a bite out of its top edge.", bundle: .module)
            }
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

    var cameraSection: some View {
        Section {
            if model.manifest.hasCamera {
                Toggle(String(localized: "Show camera", bundle: .module), isOn: Binding(
                    get: { model.edit.camera.isVisible },
                    set: { value in model.change { $0.camera.isVisible = value } }
                ))
                Toggle(String(localized: "Fill the frame", bundle: .module), isOn: Binding(
                    get: { model.edit.camera.isFullscreen },
                    set: { value in model.change { $0.camera.isFullscreen = value } }
                ))
                .disabled(!model.edit.camera.isVisible)
                cameraBubbleControls
            } else {
                LabeledContent(String(localized: "Camera", bundle: .module)) {
                    Text("Not recorded", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Camera", bundle: .module)
        } footer: {
            if model.manifest.hasCamera {
                Text("Drag the bubble on the preview to place it, or drag its corner to resize.", bundle: .module)
            } else {
                Text("This recording has no camera track.", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private var cameraBubbleControls: some View {
        let bubbled = model.edit.camera.isVisible && !model.edit.camera.isFullscreen
        Picker(String(localized: "Corner", bundle: .module), selection: Binding(
            get: { model.edit.camera.placement },
            set: { value in model.snapCamera(to: value) }
        )) {
            ForEach(BubblePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .disabled(!bubbled)
        KadrSlider(
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
        .disabled(!bubbled)
        KadrSlider(
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
        .disabled(!model.edit.camera.isVisible)
    }
}
