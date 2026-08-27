import SettingsKit
import SwiftUI

/// Quick Access Overlay settings (docs/03 §8.3): corner, size, timeout, stacking.
struct OverlayPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Show cards in the", selection: $settings.overlayCorner) {
                    ForEach(OverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                Toggle("Always on the main display", isOn: $settings.overlayOnPrimaryDisplay)
                Text("Otherwise cards appear on the display the capture came from.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Slider(
                    value: Binding(
                        get: { Double(settings.overlayCardWidth) },
                        set: { settings.overlayCardWidth = Int($0) }
                    ),
                    in: 140 ... 420,
                    step: 20
                ) {
                    Text("Card size")
                } minimumValueLabel: {
                    Text("S").font(.caption)
                } maximumValueLabel: {
                    Text("L").font(.caption)
                }

                Stepper(
                    "Stack up to \(settings.overlayMaxVisibleCards) cards",
                    value: $settings.overlayMaxVisibleCards,
                    in: 1 ... 10
                )
            }

            Section {
                Picker("Dismiss cards", selection: $settings.overlayTimeout) {
                    ForEach(OverlayTimeout.allCases, id: \.self) { timeout in
                        Text(timeout.title).tag(timeout)
                    }
                }
                Toggle("Dismiss a card when it is dragged out", isOn: $settings.overlayDismissOnDrag)
                Text("Dismissing a card never deletes its file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
