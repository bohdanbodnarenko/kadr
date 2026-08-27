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
