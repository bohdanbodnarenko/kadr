import Foundation

/// The single keys that work while the recorder is open (docs/03 §1.4).
///
/// The island can be opened, and a mode picked, without touching the mouse — and then the
/// recorder asked for a click to do the one thing it exists for. These finish the path:
/// pick a target, set the inputs, start, or step back out.
///
/// The letters are the island's where they overlap — A area, W window, F full screen — so
/// the same key means the same thing on both surfaces and nobody has to learn the recorder
/// separately. The rest are the first letter of what they toggle, and no letter is used
/// twice.
nonisolated enum RecordSetupKey: Equatable, Sendable {
    case area
    case window
    case screen
    case microphone
    case systemAudio
    case camera
    case clicks
    case keystrokes
    case teleprompter
    case record
    case back

    /// What a key press means, or nil for a key the recorder does not answer to.
    ///
    /// Modifiers are left alone: ⌘W belongs to the window and ⌘Q to the app, and a bar that
    /// swallowed either would be a bar nobody could get out of.
    static func match(_ characters: String, isReturn: Bool = false, isEscape: Bool = false) -> RecordSetupKey? {
        if isEscape {
            return .back
        }
        if isReturn {
            return .record
        }
        guard let character = characters.lowercased().first else { return nil }
        return byLetter[character]
    }

    /// The letters, as a table rather than a switch: this is data about the recorder's
    /// controls, and a test reads it to check that no key does two jobs.
    static let byLetter: [Character: RecordSetupKey] = [
        "a": .area,
        "w": .window,
        "f": .screen,
        "m": .microphone,
        "s": .systemAudio,
        "c": .camera,
        "h": .clicks,
        "k": .keystrokes,
        "t": .teleprompter,
        "r": .record
    ]

    /// The caption shown under the control in its hover tooltip.
    var caption: String {
        switch self {
        case .area: "A"
        case .window: "W"
        case .screen: "F"
        case .microphone: "M"
        case .systemAudio: "S"
        case .camera: "C"
        case .clicks: "H"
        case .keystrokes: "K"
        case .teleprompter: "T"
        case .record: "return"
        case .back: "esc"
        }
    }
}
