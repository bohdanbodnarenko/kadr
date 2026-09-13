import StudioSession
import SwiftUI

extension StudioInspector {
    // MARK: - Overlays

    var overlaySection: some View {
        StudioInspectorSection(title: "On top", key: "overlays") {
            pointerControls
            clickControls
            Toggle("Enable zooms", isOn: Binding(
                get: { model.edit.showsZooms },
                set: { value in model.change { $0.showsZooms = value } }
            ))
            if model.edit.showsZooms {
                Picker("Zoom motion", selection: Binding(
                    get: { model.edit.zoomStyle },
                    set: { value in model.change { $0.zoomStyle = value } }
                )) {
                    ForEach(ZoomAnimationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            InspectorSlider(
                title: "Motion blur",
                value: Binding(
                    get: { model.edit.motionBlur },
                    set: { value in
                        model.change(coalescingAs: "motion.blur") { $0.motionBlur = value }
                    }
                ),
                range: 0 ... 1,
                format: .percent
            )
            keystrokeControls
        }
    }

    @ViewBuilder
    private var pointerControls: some View {
        Toggle("Draw the pointer", isOn: Binding(
            get: { model.edit.showsCursor },
            set: { value in model.change { $0.showsCursor = value } }
        ))
        .disabled(model.manifest.hasBakedCursor)
        if !model.manifest.hasBakedCursor {
            InspectorSlider(
                title: "Pointer size",
                value: Binding(
                    get: { model.edit.cursorScale },
                    set: { value in
                        model.change(coalescingAs: "cursor.scale") { $0.cursorScale = value }
                    }
                ),
                range: StudioEdit.minimumCursorScale ... StudioEdit.maximumCursorScale,
                format: .multiplier
            )
            Picker("Pointer motion", selection: Binding(
                get: { model.edit.cursorSmoothing },
                set: { value in model.change { $0.cursorSmoothing = value } }
            )) {
                ForEach(CursorSmoothing.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        if model.manifest.hasBakedCursor {
            Text("This recording already has the pointer in it. Record without it to have "
                + "the studio draw a smooth one instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var clickControls: some View {
        Toggle("Ripple on clicks", isOn: Binding(
            get: { model.edit.showsClicks },
            set: { value in model.change { $0.showsClicks = value } }
        ))
        if model.edit.showsClicks {
            Picker("Ripple", selection: Binding(
                get: { model.edit.clickStyle },
                set: { value in model.change { $0.clickStyle = value } }
            )) {
                ForEach(ClickRippleStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Press into the screen", isOn: Binding(
                get: { model.edit.showsClickPress },
                set: { value in model.change { $0.showsClickPress = value } }
            ))
            InspectorSlider(
                title: "Ripple size",
                value: Binding(
                    get: { model.edit.clickScale },
                    set: { value in
                        model.change(coalescingAs: "click.scale") { $0.clickScale = value }
                    }
                ),
                range: StudioEdit.minimumCursorScale ... StudioEdit.maximumCursorScale,
                format: .multiplier
            )
            ColorPicker(
                "Ripple colour",
                selection: Binding(
                    get: { Color(model.edit.clickColor) },
                    set: { color in
                        model.change(coalescingAs: "click.color") { $0.clickColor = StudioColor(color) }
                    }
                ),
                supportsOpacity: false
            )
        }
    }

    @ViewBuilder
    private var keystrokeControls: some View {
        Toggle("Caption shortcuts", isOn: Binding(
            get: { model.edit.showsKeystrokes },
            set: { value in model.change { $0.showsKeystrokes = value } }
        ))
        if model.edit.showsKeystrokes {
            Text("Position")
                .font(.callout)
                .foregroundStyle(.secondary)
            overlayPlacementGrid(selection: Binding(
                get: { model.edit.keystrokePlacement },
                set: { value in model.change { $0.keystrokePlacement = value } }
            ))
            InspectorSlider(
                title: "Size",
                value: Binding(
                    get: { model.edit.keystrokeScale },
                    set: { value in
                        model.change(coalescingAs: "keystroke.scale") { $0.keystrokeScale = value }
                    }
                ),
                range: StudioEdit.minimumOverlayScale ... StudioEdit.maximumOverlayScale,
                format: .multiplier
            )
        }
    }
}
