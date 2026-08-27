import SettingsKit
import SwiftUI

/// History settings (docs/03 §5, §8.3): retention and the library size cap.
struct HistoryPane: View {
    @Bindable var settings: AppSettings
    var history: HistoryController?

    var body: some View {
        Form {
            Section {
                Picker("Keep captures", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                Text("Session-only clears the library the next time Kadr launches. "
                    + "Deleting from History always removes the file Kadr stored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Library size limit", selection: $settings.historySizeCap) {
                    ForEach(HistorySizeCap.allCases, id: \.self) { cap in
                        Text(cap.title).tag(cap)
                    }
                }
                Text("When the library is over the limit, the captures you have not "
                    + "opened or dragged out recently are removed first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.historyRetention) { _, _ in history?.applySettingsChange() }
        .onChange(of: settings.historySizeCap) { _, _ in history?.applySettingsChange() }
    }
}
