import KeyboardShortcuts
import SwiftUI

/// A recorder for every global command (docs/03 §8.3, docs/16 X-2).
struct ShortcutsPane: View {
    var body: some View {
        Form {
            ForEach(CaptureCommand.shortcutSections, id: \.title) { group in
                section(group.title, group.commands)
            }
            Section {
                Button("Restore All Shortcuts") {
                    HotkeyCenter.restoreAll()
                }
            } footer: {
                Text(
                    "Shortcuts work in every app, so only a few are set out of the box — the "
                        + "capture island reaches every mode with one key. Option alone is refused: "
                        + "macOS 15 drops those."
                )
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
                        // Only where there is a default to go back to; the recorder's own
                        // clear button already covers the rest.
                        if command.shortcutName.initialShortcut != nil {
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
}
