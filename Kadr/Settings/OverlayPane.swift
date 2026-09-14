import SettingsKit
import Shared
import SwiftUI

/// Quick Access Overlay settings (docs/03 §8.3): corner, size, timeout, stacking.
struct OverlayPane: View {
    /// The sizes worth offering. Round numbers people recognise from upload limits, rather
    /// than a slider that invites picking 237 KB.
    private static let compressionTargets = [
        128 * 1024, 256 * 1024, 512 * 1024, 1024 * 1024, 2 * 1024 * 1024
    ]

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
                Toggle("Return saves the hovered card", isOn: $settings.overlayReturnSaves)
                Toggle("Always show actions", isOn: $settings.overlayAlwaysShowActions)
                Text(
                    "Dismissing a card never deletes its file. Hovering or dragging pauses auto-dismiss. "
                        + "Hover shows Copy, Save, Annotate or Studio, and Share — the picture stays visible."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Card buttons") {
                CardLayoutEditor(settings: settings)
            }

            Section("Compress") {
                Picker("Format", selection: $settings.compressionFormat) {
                    ForEach(CompressedImageFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                Picker("Aim for", selection: $settings.compressionTargetBytes) {
                    ForEach(Self.compressionTargets, id: \.self) { bytes in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .tag(bytes)
                    }
                }
                Text("Compressing copies a smaller version to the clipboard. "
                    + "The capture itself is left at full quality.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormChrome()
    }
}
