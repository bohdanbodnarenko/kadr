import KeyboardShortcuts
import SwiftUI

/// A recorder for every global command (docs/03 §8.3, docs/16 X-2).
///
/// A shortcut another app already holds is the likeliest first-run complaint: it fails
/// without a sound. `HotkeyHealth` has always known which ones failed; this is where it
/// finally says so, under the recorder that needs a different key (docs/17 T-SH-7).
struct ShortcutsPane: View {
    /// Nil only where there is no running hotkey center (previews, tests).
    var health: HotkeyHealth?
    /// Bumped on every change so Restore Default re-reads whether it is needed.
    @State private var revision = 0

    var body: some View {
        Form {
            ForEach(CaptureCommand.shortcutSections, id: \.title) { group in
                section(group.title, group.commands)
            }
            Section {
                Button("Restore All Shortcuts") {
                    HotkeyCenter.restoreAll()
                    shortcutsChanged()
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
                        KeyboardShortcuts.Recorder(command.shortcutTitle, name: command.shortcutName) { _ in
                            shortcutsChanged()
                        }
                        .shortcutValidation(HotkeyCenter.validator(for: command))
                        // Only where there is a default to go back to; the recorder's own
                        // clear button already covers the rest.
                        if command.shortcutName.initialShortcut != nil {
                            Button("Restore Default") {
                                HotkeyCenter.restoreDefault(for: command)
                                shortcutsChanged()
                            }
                            .controlSize(.small)
                            .disabled(Self.isDefault(command, revision: revision))
                        }
                    }
                    if let message = health?.message(for: command) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(command.shortcutTitle): \(message). Record a different shortcut.")
                    }
                }
            }
        }
    }

    private func shortcutsChanged() {
        revision += 1
        health?.reprobe()
    }

    /// Whether the command's shortcut is what it shipped with. `revision` is only there to
    /// make SwiftUI re-ask after a change, since `KeyboardShortcuts` is not observable.
    static func isDefault(_ command: CaptureCommand, revision: Int = 0) -> Bool {
        _ = revision
        return KeyboardShortcuts.getShortcut(for: command.shortcutName) == command.shortcutName.initialShortcut
    }
}
