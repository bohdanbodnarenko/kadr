import SettingsKit
import SwiftUI

/// The Settings window's content (docs/03 §8.3).
///
/// Only General and Shortcuts exist at this milestone; Overlay, Capture, Recording,
/// History and Advanced arrive with the features they configure.
struct SettingsView: View {
    let settings: AppSettings
    let loginItem: LoginItemController

    var body: some View {
        TabView {
            GeneralPane(settings: settings, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 540, height: 380)
    }
}
