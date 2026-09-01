import StudioSession
import SwiftUI

extension StudioInspector {
    @ViewBuilder
    var selectedZoomSection: some View {
        if let id = model.selectedZoom, let cue = model.edit.zooms.first(where: { $0.id == id }) {
            StudioInspectorSection(title: "Zoom", key: "zoom") {
                Toggle("Use this zoom", isOn: Binding(
                    get: { cue.isEnabled },
                    set: { value in model.updateZoom(id) { $0.isEnabled = value } }
                ))
                zoomFocusRow(id: id, cue: cue)
                InspectorSlider(
                    title: "Starts at",
                    value: Binding(
                        get: { cue.start },
                        set: { value in model.moveZoom(id, to: value) }
                    ),
                    range: 0 ... max(model.edit.duration, 1),
                    format: .seconds
                )
                Button("Move to playhead") { model.moveZoom(id, to: model.playhead) }
                    .controlSize(.small)
                if !cue.anchor.followsPointer {
                    Button("Aim at the pointer") { model.aimSelectedZoomAtPointer() }
                        .controlSize(.small)
                        .disabled(!model.hasPointerAtPlayhead)
                        .help("Point this zoom at where the pointer was at the playhead")
                    StudioZoomFocusPad(
                        position: Binding(
                            get: { model.normalizedZoomAnchor(for: id) },
                            set: { model.setZoomAnchor(id, toNormalized: $0) }
                        ),
                        magnification: cue.magnification,
                        aspect: model.manifest.pixelSize
                    )
                }
                InspectorSlider(
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
                InspectorSlider(
                    title: "Hold",
                    value: Binding(
                        get: { cue.duration },
                        set: { value in model.updateZoom(id, coalescingAs: "zoom.hold") { $0.duration = value } }
                    ),
                    // Thirty seconds, or the recording if it is shorter — not the whole
                    // recording. A slider that spans ten minutes puts every useful hold in
                    // its first two pixels, and a zoom nobody holds for nine minutes is not
                    // worth making the other case unusable for.
                    range: 0.2 ... min(max(model.edit.duration, 1), 30),
                    format: .seconds
                )
                InspectorSlider(
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
                Button("Remove zoom", role: .destructive) { model.removeSelectedZoom() }
            }
        }
    }

    private func zoomFocusRow(id: ZoomCue.ID, cue: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Focus")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(StudioZoomFocus.allCases, id: \.self) { focus in
                    Button(focus.title) { model.setZoomFocus(id, to: focus) }
                        .buttonStyle(.bordered)
                        .tint(model.zoomFocus(of: id) == focus ? .accentColor : .secondary)
                        .controlSize(.small)
                }
            }
            if cue.anchor.followsPointer {
                Text("The camera stays on the pointer for the life of this zoom.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                InspectorSlider(
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
            }
        }
    }
}
