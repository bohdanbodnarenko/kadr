import ControlKit
import StudioSession
import SwiftUI

/// The selected zoom cue (docs/09 U3.4).
@MainActor
extension StudioInspector {
    @ViewBuilder
    var selectedZoomSection: some View {
        if let id = model.selectedZoom, let cue = model.edit.zooms.first(where: { $0.id == id }) {
            Section {
                zoomNavigationRow(id: id)
                Toggle(String(localized: "Use this zoom", bundle: .module), isOn: Binding(
                    get: { cue.isEnabled },
                    set: { value in model.updateZoom(id) { $0.isEnabled = value } }
                ))
                zoomFocusControls(id: id, cue: cue)
                zoomTimingControls(id: id, cue: cue)
                HStack {
                    Button(String(localized: "Move to Playhead", bundle: .module)) {
                        model.moveZoom(id, to: model.playhead)
                    }
                    Spacer(minLength: 0)
                    Button(String(localized: "Remove", bundle: .module), role: .destructive) {
                        model.removeSelectedZoom()
                    }
                }
            } header: {
                Text("Zoom \(zoomPosition(of: id))", bundle: .module)
            } footer: {
                if cue.anchor.followsPointer {
                    Text("The camera stays on the pointer for the life of this zoom.", bundle: .module)
                }
            }
        } else {
            Section {
                Text(
                    "Select a zoom on the timeline to edit it, or press Z to add one at the playhead.",
                    bundle: .module
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Zoom", bundle: .module)
            }
        }
    }

    private func zoomPosition(of id: ZoomCue.ID) -> String {
        let ordered = model.zoomsInOrder
        let index = (ordered.firstIndex { $0.id == id } ?? 0) + 1
        return "\(index) of \(ordered.count)"
    }

    /// Which zoom this is, the way to the others, and a way to watch it.
    private func zoomNavigationRow(id: ZoomCue.ID) -> some View {
        let ordered = model.zoomsInOrder
        let index = ordered.firstIndex { $0.id == id } ?? 0
        return LabeledContent(String(localized: "Step through", bundle: .module)) {
            HStack(spacing: 6) {
                Button {
                    model.selectAdjacentZoom(forward: false)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0)
                .help(Text("Previous zoom ([)", bundle: .module))
                .accessibilityLabel(Text("Previous zoom", bundle: .module))
                Button {
                    model.selectAdjacentZoom(forward: true)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index >= ordered.count - 1)
                .help(Text("Next zoom (])", bundle: .module))
                .accessibilityLabel(Text("Next zoom", bundle: .module))
                Button {
                    model.previewZoom(id)
                } label: {
                    Label(String(localized: "Play", bundle: .module), systemImage: "play.fill")
                }
                .help(Text("Play this zoom from just before it starts (Return)", bundle: .module))
            }
        }
    }

    @ViewBuilder
    private func zoomFocusControls(id: ZoomCue.ID, cue: ZoomCue) -> some View {
        Picker(String(localized: "Focus", bundle: .module), selection: Binding(
            get: { model.zoomFocus(of: id) },
            set: { value in model.setZoomFocus(id, to: value) }
        )) {
            ForEach(StudioZoomFocus.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if cue.anchor.followsPointer {
            KadrSlider(
                title: "Edge in frame",
                value: Binding(
                    get: { cue.boundsBias },
                    set: { value in
                        model.updateZoom(id, coalescingAs: "zoom.bias") { $0.boundsBias = value }
                    }
                ),
                range: 0 ... 1,
                format: .percent
            )
        } else {
            Button(String(localized: "Aim on Preview…", bundle: .module)) { model.beginAimingZoom(id) }
                .help(Text("Place this zoom's frame on the picture itself", bundle: .module))
            StudioZoomFocusPad(
                position: Binding(
                    get: { model.normalizedZoomAnchor(for: id) },
                    set: { model.setZoomAnchor(id, toNormalized: $0) }
                ),
                magnification: cue.magnification,
                aspect: model.manifest.pixelSize
            )
            Button(String(localized: "Aim at the Pointer", bundle: .module)) { model.aimSelectedZoomAtPointer() }
                .disabled(!model.hasPointerAtPlayhead)
                .help(Text("Point this zoom at where the pointer was at the playhead", bundle: .module))
        }
    }

    @ViewBuilder
    private func zoomTimingControls(id: ZoomCue.ID, cue: ZoomCue) -> some View {
        KadrSlider(
            title: "Magnification",
            value: Binding(
                get: { cue.magnification },
                set: { value in
                    model.updateZoom(id, coalescingAs: "zoom.magnification") { $0.magnification = value }
                }
            ),
            range: 1 ... ZoomCue.maximumMagnification,
            format: .multiplier
        )
        KadrSlider(
            title: "Starts at",
            value: Binding(
                // Edited time both ways: `cue.start` is source time, and after a cut the
                // slider showed one clock and moved the cue on the other.
                get: { model.editedDisplayRange(of: cue).lowerBound },
                set: { value in model.moveZoom(id, to: value) }
            ),
            range: 0 ... max(model.edit.duration, 1),
            format: .seconds
        )
        KadrSlider(
            title: "Hold",
            value: Binding(
                get: { cue.duration },
                set: { value in model.updateZoom(id, coalescingAs: "zoom.hold") { $0.duration = value } }
            ),
            // Thirty seconds, or the recording if it is shorter — not the whole recording. A
            // slider that spans ten minutes puts every useful hold in its first two pixels,
            // and a zoom nobody holds for nine minutes is not worth making the other case
            // unusable for.
            range: 0.2 ... min(max(model.edit.duration, 1), 30),
            format: .seconds
        )
        KadrSlider(
            title: "Move",
            value: Binding(
                get: { cue.transitionDuration },
                set: { value in
                    model.updateZoom(id, coalescingAs: "zoom.move") { $0.transitionDuration = value }
                }
            ),
            range: 0.1 ... 2,
            format: .seconds
        )
    }
}
