import AutomationKit
import SettingsKit
import SwiftUI

/// The Settings window's content (docs/03 §8.3).
///
/// The tab selection is bound rather than left to `TabView` so `kadr open-settings
/// --tab capture` can land on a pane (docs/03 §8.4).
struct SettingsView: View {
    let settings: AppSettings
    let loginItem: LoginItemController
    var history: HistoryController?
    @State var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralPane(settings: settings, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            OverlayPane(settings: settings)
                .tabItem { Label("Overlay", systemImage: "rectangle.stack") }
                .tag(SettingsTab.overlay)

            CapturePane(settings: settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(SettingsTab.capture)

            RecordingPane(settings: settings)
                .tabItem { Label("Recording", systemImage: "record.circle") }
                .tag(SettingsTab.recording)

            HistoryPane(settings: settings, history: history)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(SettingsTab.history)

            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)

            UpdatesPane(updater: .shared)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)

            AdvancedPane(settings: settings)
                .tabItem { Label("Advanced", systemImage: "terminal") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 540, height: 420)
    }
}
