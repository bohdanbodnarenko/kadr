import KeyboardShortcuts
import SwiftUI

/// A recorder for every global command (docs/03 §8.3).
///
/// Every recorder runs the same validation, so an Option-only shortcut is refused
/// wherever it is typed (docs/04 §3.2).
struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(CaptureCommand.allCases, id: \.self) { command in
                    KeyboardShortcuts.Recorder(command.shortcutTitle, name: command.shortcutName)
                        .shortcutValidation(HotkeyCenter.validate)
                }
            } footer: {
                Text("Shortcuts work in every app. Option alone is refused — macOS 15 drops those.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormChrome()
    }
}
