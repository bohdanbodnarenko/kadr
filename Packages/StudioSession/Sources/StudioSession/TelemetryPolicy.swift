import CoreGraphics
import Foundation

/// The decisions the pointer recorder makes, without the plumbing that makes them
/// (docs/09 U3.1).
///
/// The recorder itself has to live in the agent — it needs `CGEvent`, `NSCursor` and the
/// TCC grant, none of which belong in a model package. What can be lifted out is every
/// judgement it makes: which key presses are safe to write down, how often to record a
/// position, when to give up on one capture method and try the next. Those are the parts
/// that would otherwise be untestable and are exactly the parts worth testing.
public enum TelemetryPolicy {
    // MARK: - Privacy

    /// Modifier keys, as a set, for deciding whether a press is a chord.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        /// Shift alone is how capital letters are typed, so it does not make a chord —
        /// treating it as one would record every capitalised word somebody types.
        public static let chordMaking: Modifiers = [.command, .option, .control, .function]

        public var makesChord: Bool {
            !intersection(.chordMaking).isEmpty
        }

        /// The symbols, in the order macOS shows them.
        public var symbols: String {
            var result = ""
            if contains(.control) {
                result += "⌃"
            }
            if contains(.option) {
                result += "⌥"
            }
            if contains(.shift) {
                result += "⇧"
            }
            if contains(.command) {
                result += "⌘"
            }
            return result
        }
    }

    /// Keys worth captioning on their own, without any modifier.
    ///
    /// Navigation and commitment, not content: knowing the user pressed Return or Escape
    /// explains the recording, while knowing which letters they typed is a transcript of
    /// their password.
    public enum SpecialKey: String, Sendable, CaseIterable {
        case returnKey, enter, tab, escape, delete, forwardDelete
        case upArrow, downArrow, leftArrow, rightArrow
        case pageUp, pageDown, home, end, space
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        case f13, f14, f15, f16, f17, f18, f19
        case fn, capsLock

        public var caption: String {
            switch self {
            case .returnKey: String(localized: "Return", bundle: .module)
            case .enter: String(localized: "Enter", bundle: .module)
            case .tab: String(localized: "Tab", bundle: .module)
            case .escape: String(localized: "Esc", bundle: .module)
            case .delete: String(localized: "Delete", bundle: .module)
            case .forwardDelete: String(localized: "Fwd Delete", bundle: .module)
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .pageUp: String(localized: "Page Up", bundle: .module)
            case .pageDown: String(localized: "Page Down", bundle: .module)
            case .home: String(localized: "Home", bundle: .module)
            case .end: String(localized: "End", bundle: .module)
            case .space: String(localized: "Space", bundle: .module)
            case .f1: String(localized: "F1", bundle: .module)
            case .f2: String(localized: "F2", bundle: .module)
            case .f3: String(localized: "F3", bundle: .module)
            case .f4: String(localized: "F4", bundle: .module)
            case .f5: String(localized: "F5", bundle: .module)
            case .f6: String(localized: "F6", bundle: .module)
            case .f7: String(localized: "F7", bundle: .module)
            case .f8: String(localized: "F8", bundle: .module)
            case .f9: String(localized: "F9", bundle: .module)
            case .f10: String(localized: "F10", bundle: .module)
            case .f11: String(localized: "F11", bundle: .module)
            case .f12: String(localized: "F12", bundle: .module)
            case .f13: String(localized: "F13", bundle: .module)
            case .f14: String(localized: "F14", bundle: .module)
            case .f15: String(localized: "F15", bundle: .module)
            case .f16: String(localized: "F16", bundle: .module)
            case .f17: String(localized: "F17", bundle: .module)
            case .f18: String(localized: "F18", bundle: .module)
            case .f19: String(localized: "F19", bundle: .module)
            case .fn: String(localized: "fn", bundle: .module)
            case .capsLock: String(localized: "Caps Lock", bundle: .module)
            }
        }
    }

    /// The caption for a key press, or nil if it must not be recorded.
    ///
    /// This is the privacy rule, in one function. A press is captioned when it is a chord
    /// (⌘S, ⇧⌘4) or a special key (Return, Esc) — never when it is a character somebody
    /// typed. There is no setting to turn that off, because the sidecar travels with the
    /// recording and a keylogger that is off by default is still a keylogger in the file
    /// format.
    ///
    /// - Parameters:
    ///   - characters: what the key produces unmodified, for a chord's letter.
    ///   - specialKey: the named key, if it is one.
    ///   - modifiers: which modifiers were held.
    public static func caption(
        characters: String?,
        specialKey: SpecialKey?,
        modifiers: Modifiers,
        isRepeat: Bool = false
    ) -> String? {
        if isRepeat {
            return nil
        }
        if let specialKey {
            // A special key is worth showing with its modifiers when it has them.
            return modifiers.symbols + specialKey.caption
        }
        guard modifiers.makesChord else { return nil }
        guard let characters, !characters.isEmpty else { return nil }
        // Uppercased because a chord is conventionally written ⌘S rather than ⌘s, whatever
        // the shift state was.
        return modifiers.symbols + characters.uppercased()
    }

    // MARK: - Sampling

    /// How often the pointer's position is worth recording, in samples per second.
    ///
    /// Sixty is the display's rate and more than the eye can use; the reconstruction
    /// smooths between samples anyway, so a higher rate buys nothing but file size.
    public static let sampleRate: Double = 60

    /// Whether a new position is worth recording, given the last one.
    ///
    /// Two filters, both about not writing down nothing: a sample too soon after the last
    /// one adds a row and no information, and a sample in the same place as the last one
    /// is the pointer sitting still, which the reconstruction infers perfectly well from
    /// its absence.
    public static func shouldRecord(
        _ position: CGPoint,
        at time: TimeInterval,
        lastSample: PointerSample?,
        minimumDistance: CGFloat = 1
    ) -> Bool {
        guard let lastSample else { return true }
        guard time - lastSample.time >= 1 / sampleRate else { return false }
        let moved = hypot(position.x - lastSample.position.x, position.y - lastSample.position.y)
        return moved >= minimumDistance
    }

    // MARK: - Kadr's own chrome

    /// How far outside the recorder's own controls still counts as aiming at them.
    ///
    /// A press lands a few points from where the pointer was when it arrived, and the
    /// notch's shell grows under the pointer as it approaches; both put the recorded
    /// position just outside the rect the control occupied a moment ago.
    public static let chromeSlop: CGFloat = 8

    /// Whether a click belongs in the recording at all.
    ///
    /// Clicks on Kadr's own recording controls are not part of what was being recorded —
    /// they are the act of ending it. Kept out of the telemetry entirely rather than
    /// filtered later, because every consumer would otherwise have to know: the click
    /// ripple drawn into the picture, the zoom planner that reads a cluster of clicks as an
    /// activity worth zooming to, and the keystroke overlay all treated "stop" as content
    /// and pointed the viewer at the corner of the screen as the recording ended.
    ///
    /// - Parameters:
    ///   - point: the click, in the same space as `chrome`.
    ///   - chrome: the recorder's own controls on screen — the floating bar or the notch
    ///     island, and the menu-bar item. Empty when none is showing.
    public static func shouldRecordClick(
        at point: CGPoint,
        chrome: [CGRect],
        slop: CGFloat = chromeSlop
    ) -> Bool {
        !chrome.contains { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    // MARK: - The fallback ladder

    /// What each capture method can do, as the recorder discovers it.
    public struct Availability: Sendable, Hashable {
        /// Whether a listen-only `CGEvent` tap could be created. Needs Accessibility.
        public var hasEventTap: Bool
        /// Whether AppKit's global monitors are installed. These need no permission.
        public var hasAppKitMonitors: Bool

        public init(hasEventTap: Bool = false, hasAppKitMonitors: Bool = false) {
            self.hasEventTap = hasEventTap
            self.hasAppKitMonitors = hasAppKitMonitors
        }
    }

    /// The best source available.
    ///
    /// The ladder exists because each rung fails independently and quietly: an event tap
    /// needs Accessibility and macOS will disable one whose callback takes too long, while
    /// AppKit monitors see presses without any permission at all but miss movement over
    /// apps that do not report it. A sampler sees only where the pointer is — coarse, but
    /// never nothing, which is the point of having a floor.
    public static func source(for availability: Availability) -> TelemetrySource {
        if availability.hasEventTap {
            return .eventTap
        }
        if availability.hasAppKitMonitors {
            return .appKitMonitors
        }
        return .sampler
    }

    /// Whether the recorder should drop to the next rung.
    ///
    /// A tap macOS has disabled reports nothing and says nothing, so the recorder watches
    /// for silence: no events at all for this long while the pointer is demonstrably
    /// moving means the tap is dead rather than the user is still.
    public static let tapSilenceTimeout: TimeInterval = 2
}
