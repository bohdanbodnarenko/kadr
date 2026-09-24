import AppKit

/// What a key press means to a Quick Access card, once the overlay panel is key
/// (docs/03 §2, docs/17 T-OUT-1).
///
/// Pure so the table can be tested without a panel. The modifier rule is strict on
/// purpose: an unmodified key must arrive with *no* modifiers (⌘⌫ is Finder's "Move to
/// Trash", not ours), and a ⌘ shortcut must arrive with ⌘ alone. Anything else passes
/// through to whoever else wants it.
nonisolated enum CardKeyCommand: Equatable, Sendable {
    case delete
    case dismiss
    case quickLook
    case save
    case copy
    case annotate
    case pin

    /// Modifier bits that say nothing about intent: Caps Lock, and the flags AppKit sets
    /// on keypad and function-row keys (forward delete arrives with `.function`).
    private static let ignoredModifiers: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function]

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CardKeyCommand? {
        let relevant = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredModifiers)
        if relevant.isEmpty {
            return plain(keyCode)
        }
        if relevant == .command {
            return command(keyCode)
        }
        return nil
    }

    private static func plain(_ keyCode: UInt16) -> CardKeyCommand? {
        switch keyCode {
        case 51, 117: .delete
        case 53: .dismiss
        case 49: .quickLook
        case 36, 76: .save
        default: nil
        }
    }

    /// CleanShot §22.2: ⌘C copy, ⌘S save, ⌘E annotate (trim, for a recording), ⌘P pin,
    /// ⌘W close.
    private static func command(_ keyCode: UInt16) -> CardKeyCommand? {
        switch keyCode {
        case 8: .copy
        case 1: .save
        case 14: .annotate
        case 35: .pin
        case 13: .dismiss
        default: nil
        }
    }
}
