import SettingsKit
import SwiftUI

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
            }

            Section("Window capture") {
                Toggle("Include the window's shadow", isOn: $settings.windowShadow)
                Toggle("Keep the window's transparency", isOn: $settings.transparentWindowBackground)
                Text("Hold ⌥ when picking a window to invert the shadow setting for one capture.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Capture Text") {
                Toggle("Keep line breaks", isOn: $settings.ocrPreservesLineBreaks)
                Text("Off folds recognised lines into spaces, which suits copying a paragraph.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Scrolling Capture") {
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
        }
        .formStyle(.grouped)
    }
}
