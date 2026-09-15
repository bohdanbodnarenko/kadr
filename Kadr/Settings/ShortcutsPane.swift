import KeyboardShortcuts
import SwiftUI

/// A recorder for every global command (docs/03 §8.3, docs/16 X-2).
struct ShortcutsPane: View {
    var body: some View {
        Form {
            section("Capture", CaptureCommand.menuCommands)
            section("Utilities", CaptureCommand.utilityCommands)
            section("Overlays", CaptureCommand.overlayCommands)
            section("Recording", CaptureCommand.recordingCommands + [.stopRecording, .recordSetup])
            section("Library", [.openHistory, .openSaveFolder])
            Section {
                Button("Restore All Shortcuts") {
                    HotkeyCenter.restoreAll()
                }
            } footer: {
                Text("Shortcuts work in every app. Option alone is refused — macOS 15 drops those.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormChrome()
    }

    private func section(_ title: String, _ commands: [CaptureCommand]) -> some View {
        Section(title) {
            ForEach(commands, id: \.self) { command in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        KeyboardShortcuts.Recorder(command.shortcutTitle, name: command.shortcutName)
                            .shortcutValidation(HotkeyCenter.validator(for: command))
                        Button("Restore Default") {
                            HotkeyCenter.restoreDefault(for: command)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
