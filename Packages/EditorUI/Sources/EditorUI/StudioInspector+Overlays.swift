import ControlKit
import Shared
import StudioSession
import SwiftUI

/// What the studio draws on top of the recording (docs/09 U3.4).
///
/// One section per thing that can be switched on, rather than one "On top" group holding
/// four unrelated switches and nine controls belonging to whichever of them is enabled.
/// Each section's controls are the ones its switch turns on, so the group empties and fills
/// as a unit and nothing is ever enabled-looking but inert.
@MainActor
extension StudioInspector {
    // MARK: - Pointer

    var pointerSection: some View {
        Section {
            Toggle(String(localized: "Draw pointer", bundle: .module), isOn: Binding(
                get: { model.edit.showsCursor },
                set: { value in model.change { $0.showsCursor = value } }
            ))
            .disabled(model.manifest.hasBakedCursor)
            if !model.manifest.hasBakedCursor, model.edit.showsCursor {
                KadrSlider(
                    title: "Size",
                    value: Binding(
                        get: { model.edit.cursorScale },
                        set: { value in
                            model.change(coalescingAs: "cursor.scale") { $0.cursorScale = value }
                        }
                    ),
                    range: StudioEdit.minimumCursorScale ... StudioEdit.maximumCursorScale,
                    format: .multiplier
                )
                Picker(String(localized: "Motion", bundle: .module), selection: Binding(
                    get: { model.edit.cursorSmoothing },
                    set: { value in model.change { $0.cursorSmoothing = value } }
                )) {
                    ForEach(CursorSmoothing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Pointer", bundle: .module)
        } footer: {
            if model.manifest.hasBakedCursor {
                Text("This recording already has the pointer in it. Record without it to have the "
                    + "studio draw a smooth one instead.")
            }
        }
    }

    // MARK: - Clicks

    var clickSection: some View {
        Section {
            Toggle(String(localized: "Ripple on clicks", bundle: .module), isOn: Binding(
                get: { model.edit.showsClicks },
                set: { value in model.change { $0.showsClicks = value } }
            ))
            if model.edit.showsClicks {
                Picker(String(localized: "Style", bundle: .module), selection: Binding(
                    get: { model.edit.clickStyle },
                    set: { value in model.change { $0.clickStyle = value } }
                )) {
                    ForEach(ClickRippleStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(String(localized: "Press into the screen", bundle: .module), isOn: Binding(
                    get: { model.edit.showsClickPress },
                    set: { value in model.change { $0.showsClickPress = value } }
                ))
                KadrSlider(
                    title: "Size",
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
                    "Color",
                    selection: Binding(
                        get: { Color(model.edit.clickColor) },
                        set: { color in
                            model.change(coalescingAs: "click.color") { $0.clickColor = StudioColor(color) }
                        }
                    ),
                    supportsOpacity: false
                )
            }
        } header: {
            Text("Clicks", bundle: .module)
        }
    }

    // MARK: - Zoom motion

    /// How zooms move, as opposed to where they are — that is the timeline's job and the
    /// Clip pane's.
    var zoomMotionSection: some View {
        Section {
            Toggle(String(localized: "Use zooms", bundle: .module), isOn: Binding(
                get: { model.edit.showsZooms },
                set: { value in model.change { $0.showsZooms = value } }
            ))
            if model.edit.showsZooms {
                Picker(String(localized: "Motion", bundle: .module), selection: Binding(
                    get: { model.edit.zoomStyle },
                    set: { value in model.change { $0.zoomStyle = value } }
                )) {
                    ForEach(ZoomAnimationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                KadrSlider(
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
            }
        } header: {
            Text("Zoom", bundle: .module)
        } footer: {
            Text("Zooms are placed on the timeline. This is how they travel.", bundle: .module)
        }
    }

    // MARK: - Shortcuts

    var keystrokeSection: some View {
        Section {
            Toggle(String(localized: "Caption shortcuts", bundle: .module), isOn: Binding(
                get: { model.edit.showsKeystrokes },
                set: { value in model.change { $0.showsKeystrokes = value } }
            ))
            if model.edit.showsKeystrokes {
                OverlayPlacementPicker(selection: Binding(
                    get: { model.edit.keystrokePlacement },
                    set: { value in model.change { $0.keystrokePlacement = value } }
                ))
                KadrSlider(
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
                Picker(String(localized: "Theme", bundle: .module), selection: Binding(
                    get: { model.edit.keystrokeAppearance },
                    set: { value in model.change { $0.keystrokeAppearance = value } }
                )) {
                    ForEach(OverlayChromeAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Shortcuts", bundle: .module)
        } footer: {
            if model.edit.showsKeystrokes {
                Text("Keys pressed during the recording appear as they are typed.", bundle: .module)
            }
        }
    }
}
