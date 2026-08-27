import SettingsKit
import SwiftUI

/// The Settings window's content (docs/03 §8.3).
///
/// General, Capture and Shortcuts exist so far; Overlay, Recording, History and
/// Advanced arrive with the features they configure.
struct SettingsView: View {
    let settings: AppSettings
    let loginItem: LoginItemController

    var body: some View {
        TabView {
            GeneralPane(settings: settings, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            CapturePane(settings: settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }

            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 540, height: 380)
    }
}
