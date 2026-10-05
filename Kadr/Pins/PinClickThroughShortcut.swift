import AppKit
import KeyboardShortcuts

/// The click-through shortcut as the user has it bound, for every place a pin names it
/// (docs/18 OUT-15).
///
/// It is rebindable in Settings ▸ Shortcuts, yet three labels promised ⌘⌥L whatever the
/// binding — and a click-through pin cannot be clicked, so a wrong promise strands it.
@MainActor
enum PinClickThroughShortcut {
    /// `⌥⌘L`, or nil when the shortcut is unbound.
    static var symbol: String? {
        KeyboardShortcuts.getShortcut(for: .togglePinClickThrough)?.description
    }

    /// The badge on a click-through pin.
    static var badge: String {
        symbol.map { String(localized: "\($0) to interact") } ?? String(localized: "Click-through")
    }

    /// What VoiceOver hears when click-through turns on.
    static var announcement: String {
        guard let symbol else {
            return String(localized: "Click-through on. Use the Kadr menu bar item to turn it off.")
        }
        return String(localized: "Click-through on. Press \(symbol) to interact.")
    }

    /// The pin image's accessibility help.
    static var help: String {
        symbol.map { String(localized: "Press \($0) to toggle click-through.") }
            ?? String(localized: "Click-through is in the pin's menu.")
    }

    /// Whether `event` is the bound shortcut, for a pin that has the keyboard: the global
    /// hotkey is registered only while some pin is click-through.
    static func matches(_ event: NSEvent) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .togglePinClickThrough) else { return false }
        return KeyboardShortcuts.Shortcut(event: event) == shortcut
    }
}
