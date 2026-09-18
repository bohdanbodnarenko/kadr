import Foundation
import Shared

/// The utilities that used to be top-level rows in the menu-bar menu (docs/03 §7, §8.1).
///
/// The island is where capturing starts now, so the things done *around* a capture — a
/// timed shot, freezing the screen, clearing the desktop, pinning the clipboard — sit one
/// menu away from the modes rather than in a twenty-row status menu.
nonisolated enum AllInOneTool: String, CaseIterable, Sendable {
    case previousArea
    case selfTimer
    case freezeScreen
    case desktopIcons
    case pinClipboard
    case systemPicker
    case captureFolder
    case history

    var title: String {
        switch self {
        case .previousArea: KadrText.string("Capture Previous Area")
        case .selfTimer: KadrText.string("Self-Timer Capture")
        case .freezeScreen: KadrText.string("Freeze Screen")
        case .desktopIcons: KadrText.string("Hide Desktop Icons")
        case .pinClipboard: KadrText.string("Pin Clipboard")
        case .systemPicker: KadrText.string("Capture with the macOS Picker…")
        case .captureFolder: KadrText.string("Open Capture Folder")
        case .history: KadrText.string("History…")
        }
    }

    var symbol: String {
        switch self {
        case .previousArea: "arrow.counterclockwise.square"
        case .selfTimer: "timer"
        case .freezeScreen: "snowflake"
        case .desktopIcons: "eye.slash"
        case .pinClipboard: "pin"
        case .systemPicker: "macwindow.on.rectangle"
        case .captureFolder: "folder"
        case .history: "clock"
        }
    }

    /// Single key while the island is key, shown beside each row of the Tools menu.
    ///
    /// Chosen to avoid the mode keys (A W F R G S T P), Return and Escape; mnemonic where a
    /// free letter allows it — L for last area, D for delay, Z for freeze, H for hide,
    /// V for paste, O for open, Y for history's neighbour on the keyboard.
    var shortcut: Character {
        switch self {
        case .previousArea: "l"
        case .selfTimer: "d"
        case .freezeScreen: "z"
        case .desktopIcons: "h"
        case .pinClipboard: "v"
        case .systemPicker: "k"
        case .captureFolder: "o"
        case .history: "y"
        }
    }

    static func matching(shortcut raw: String) -> AllInOneTool? {
        guard let character = raw.lowercased().first else { return nil }
        return allCases.first { $0.shortcut == character }
    }

    /// Where a divider goes: capture helpers, then screen helpers, then the library.
    static let groups: [[AllInOneTool]] = [
        [.previousArea, .selfTimer, .systemPicker],
        [.freezeScreen, .desktopIcons, .pinClipboard],
        [.captureFolder, .history]
    ]
}
