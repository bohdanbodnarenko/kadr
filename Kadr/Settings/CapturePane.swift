import AppKit
import SettingsKit
import Shared
import SwiftUI
import UniformTypeIdentifiers

/// Capture settings (docs/03 §8.3): cursor, window shadow and background, self-timer.
///
/// Freeze and snapping are not here: freeze is not optional in Kadr (it is how area
/// capture works at all, docs/03 §1.1) and snapping is a Phase 2 feature.
struct CapturePane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Include the pointer", isOn: $settings.includesCursor)
                if DynamicRange.isAvailable {
                    Picker("Dynamic range", selection: $settings.captureDynamicRange) {
                        ForEach(DynamicRange.available, id: \.self) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    Text("HDR keeps the display's full range — worth it for video and "
                        + "photos, and misleading for interfaces, where apps that do not "
                        + "understand HDR show it washed out. Saved as HEIC or PNG, "
                        + "whatever the format setting says.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Window capture") {
                Toggle("Include the window's shadow", isOn: $settings.windowShadow)
                Toggle("Keep the window's transparency", isOn: $settings.transparentWindowBackground)
                if !settings.transparentWindowBackground {
                    Picker("Background", selection: $settings.windowBackdrop) {
                        ForEach(WindowBackdrop.allCases, id: \.self) { backdrop in
                            Text(backdrop.title).tag(backdrop)
                        }
                    }
                    Stepper(
                        "Padding: \(settings.windowBackdropPadding) pt",
                        value: $settings.windowBackdropPadding,
                        in: 0 ... 200,
                        step: 10
                    )
                    if settings.windowBackdrop == .custom {
                        Button("Choose image…") { chooseBackdropImage() }
                        if !settings.windowBackdropImagePath.isEmpty {
                            Text(URL(fileURLWithPath: settings.windowBackdropImagePath).lastPathComponent)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Hold ⌥ when picking a window to invert the shadow setting for one capture.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Beautify") {
                Picker("Beautify new screenshots", selection: $settings.autoBeautifyPreset) {
                    ForEach(AutoBeautifyPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text("Hold Shift when you press the capture hotkey to skip it for that shot. "
                    + "Window fills stay editable in the editor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Crop the notch from fullscreen screenshots", isOn: $settings.cropNotchFromFullscreen)
                Text("On a notched MacBook, a fullscreen app’s screenshot includes a black "
                    + "strip around the camera. This cuts that strip off. Area captures "
                    + "and windowed shots are left alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Capture Text") {
                Toggle("Keep line breaks", isOn: $settings.ocrPreservesLineBreaks)
                Text("Off folds recognised lines into spaces, which suits copying a paragraph.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Selection") {
                Picker("Aspect lock", selection: $settings.captureSelectionAspect) {
                    ForEach(CaptureSelectionAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                Text("Locks area capture to a ratio. ⇧-drag still forces a square. "
                    + "The All-in-One strip has the same menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Scrolling Capture") {
                Picker("Direction", selection: $settings.scrollAxis) {
                    ForEach(ScrollAxis.allCases, id: \.self) { axis in
                        Text(axis.title).tag(axis)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Let Kadr do the scrolling", isOn: $settings.scrollAutoScroll)
                Text("Off, you scroll the page yourself and Kadr grabs frames as you go — "
                    + "which needs no permission beyond Screen Recording. On, Kadr sends "
                    + "scroll events to the window instead, which macOS only allows with "
                    + "Accessibility permission. It asks the first time you use it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Scroll step: \(settings.scrollStepPoints) pt",
                    value: $settings.scrollStepPoints,
                    in: 40 ... 400,
                    step: 20
                )
                .disabled(!settings.scrollAutoScroll)

                Stepper(
                    "Capture \(settings.scrollFrameRate) frames a second",
                    value: $settings.scrollFrameRate,
                    in: 2 ... 30
                )

                Toggle("Show me joins Kadr is unsure about", isOn: $settings.scrollReviewsSeams)
                Text("A page with a banner that follows the scroll, or scrolling faster "
                    + "than the frames can follow, can leave a join Kadr cannot verify. "
                    + "It offers to keep it, retry, or hand you the raw frames.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Self-timer") {
                Picker("Wait before capturing", selection: $settings.selfTimer) {
                    ForEach(SelfTimer.allCases, id: \.self) { timer in
                        Text(timer.title).tag(timer)
                    }
                }
                .disabled(settings.customTimerSeconds > 0)

                Stepper(
                    "Custom: \(settings.customTimerSeconds) s",
                    value: $settings.customTimerSeconds,
                    in: 0 ... 60
                )
                Text("A custom value of 0 uses the preset above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Desktop") {
                Toggle("Hide icons while capturing", isOn: $settings.hideDesktopDuringCapture)
                Toggle("Hide icons while recording", isOn: $settings.hideDesktopDuringRecording)
                Picker("Wallpaper while capturing", selection: $settings.captureWallpaper) {
                    ForEach(CaptureWallpaper.allCases, id: \.self) { wallpaper in
                        Text(wallpaper.title).tag(wallpaper)
                    }
                }
                Toggle("Precision crosshair (press C on the overlay)", isOn: $settings.capturePrecisionCrosshair)
                Toggle("Snap the selection to edges Kadr finds", isOn: $settings.captureSnapsToEdges)
                Text("Kadr reads the frozen screen for window borders and dividers and "
                    + "pulls the selection onto them. Hold ⌘ while dragging to ignore them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Hides Finder icons and widgets, and can swap the wallpaper, so a "
                    + "screenshot does not include your Desktop. A crash restores the "
                    + "previous wallpaper; a Hide Desktop Icons toggle survives relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseBackdropImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.windowBackdropImagePath = url.path
    }
}
