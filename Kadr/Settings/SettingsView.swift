import SettingsKit
import SwiftUI

/// The Settings window's content (docs/03 §8.3).
///
/// General, Overlay, Capture, Shortcuts and Updates exist so far; Recording, History and
/// Advanced arrive with the features they configure.
struct SettingsView: View {
    let settings: AppSettings
    let loginItem: LoginItemController

    var body: some View {
        TabView {
            GeneralPane(settings: settings, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            OverlayPane(settings: settings)
                .tabItem { Label("Overlay", systemImage: "rectangle.stack") }

            CapturePane(settings: settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }

            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            UpdatesPane(updater: .shared)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 540, height: 380)
    }
}
