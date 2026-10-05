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
                }
            } footer: {
                if DynamicRange.isAvailable {
                    Text("HDR keeps the display's full range; SDR is safer for interface shots.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
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
            } header: {
                Text("Window capture")
            } footer: {
                Text("Hold ⌥ when picking a window to invert the shadow setting for one capture.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Beautify new screenshots", selection: $settings.autoBeautifyPreset) {
                    ForEach(AutoBeautifyPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            } header: {
                Text("Beautify")
            } footer: {
                Text("Hold Shift when you press the capture hotkey to skip beautify for that shot.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Fullscreen captures", selection: $settings.fullscreenTarget) {
                    ForEach(FullscreenTarget.allCases, id: \.self) { target in
                        Text(target.title).tag(target)
                    }
                }
                Toggle(
                    "Trim the empty notch strip from fullscreen screenshots",
                    isOn: $settings.cropNotchFromFullscreen
                )
            } footer: {
                Text(
                    "Removes the black camera strip only when that strip is empty. "
                        + "A fullscreen shot of an app that covers the menu bar is left intact."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep line breaks", isOn: $settings.ocrPreservesLineBreaks)
                Toggle("Always open a review window", isOn: $settings.ocrShowsReview)
            } header: {
                Text("Capture Text")
            } footer: {
                Text("Text is copied straight away and a toast says how many lines went to the "
                    + "clipboard, with Edit on it when a capture needs correcting. Turn this on to "
                    + "open the review window every time instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Aspect lock", selection: $settings.captureSelectionAspect) {
                    ForEach(CaptureSelectionAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                Toggle("Show what the keys do", isOn: $settings.captureShowsOverlayHints)
                Toggle("Confirm selection before capture", isOn: $settings.captureConfirmsSelection)
            } header: {
                Text("Selection")
            } footer: {
                Text("When confirm mode is on, mouse-up leaves handles until Return. ⇧-drag still "
                    + "forces a square. The All-in-One strip has the same aspect menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                DisclosureGroup("Scrolling capture") {
                    Picker("Direction", selection: $settings.scrollAxis) {
                        ForEach(ScrollAxis.allCases, id: \.self) { axis in
                            Text(axis.title).tag(axis)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Let Kadr do the scrolling", isOn: $settings.scrollAutoScroll)

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
                }
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        "Auto-scroll needs Accessibility permission. Manual scrolling needs only "
                            + "Screen Recording."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    SettingsLearnMore(topic: .scrolling)
                }
            }

            Section {
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
            } header: {
                Text("Self-timer")
            } footer: {
                Text("A custom value of 0 uses the preset above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Desktop while capturing") {
                    Toggle("Hide icons while capturing", isOn: $settings.hideDesktopDuringCapture)
                    Toggle("Hide icons while recording", isOn: $settings.hideDesktopDuringRecording)
                    Picker("Wallpaper while capturing", selection: $settings.captureWallpaper) {
                        ForEach(CaptureWallpaper.allCases, id: \.self) { wallpaper in
                            Text(wallpaper.title).tag(wallpaper)
                        }
                    }
                    if settings.captureWallpaper == .customImage {
                        // The option used to exist with no way to name the image, so it
                        // silently kept the user's wallpaper (docs/18 SH-9).
                        LabeledContent("Image") {
                            HStack {
                                Text(customWallpaperName)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Button("Choose…", action: chooseCustomWallpaper)
                            }
                        }
                    }
                    Toggle("Precision crosshair (press C on the overlay)", isOn: $settings.capturePrecisionCrosshair)
                    Toggle("Snap the selection to edges Kadr finds", isOn: $settings.captureSnapsToEdges)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        "Hides Finder icons and can swap the wallpaper. A crash restores the "
                            + "previous wallpaper."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    SettingsLearnMore(topic: .desktopHygiene)
                }
            }
        }
        .settingsFormChrome()
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

private extension CapturePane {
    var customWallpaperName: String {
        let path = settings.captureWallpaperImagePath
        return path.isEmpty ? "None chosen" : URL(fileURLWithPath: path).lastPathComponent
    }

    func chooseCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.captureWallpaperImagePath = url.path
    }
}
