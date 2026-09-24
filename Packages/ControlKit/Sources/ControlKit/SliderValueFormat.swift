import Foundation

/// How a slider's value is written and read back (docs/09 U1.5).
///
/// The point of typing into a slider is that the user can say what they mean exactly, and
/// what they type is what they see: a field showing "45%" has to accept "45%". It also has
/// to accept "45", because nobody retypes the suffix, and "0.45" is a different number that
/// somebody will eventually try — so the parser has to be forgiving without being a guess.
///
/// Kept apart from the control because parsing is where this goes wrong and a pure function
/// is where that can be caught.
public struct SliderValueFormat: Equatable, Sendable {
    /// What the number means, which decides both the suffix and the display scale.
    public enum Unit: String, Equatable, Sendable {
        /// Stored 0…1, shown 0…100 with a per-cent sign.
        case percent
        /// Shown as-is, in image pixels.
        case points
        /// Shown as-is, in screen points — a card width or a type size.
        case screenPoints
        /// Shown as-is, in words per minute.
        case wordsPerMinute
        /// Shown as-is, in degrees.
        case degrees
        /// Shown as-is, with a multiplication sign.
        case multiplier
        /// Shown as-is, with a seconds suffix.
        case seconds
        /// A bare number.
        case plain

        var suffix: String {
            switch self {
            case .percent: "%"
            case .points: " px"
            case .screenPoints: " pt"
            case .wordsPerMinute: " wpm"
            case .degrees: "°"
            case .multiplier: "×"
            case .seconds: " s"
            case .plain: ""
            }
        }

        /// What a typed value is divided by to become the stored one.
        public var displayScale: Double {
            self == .percent ? 100 : 1
        }

        /// Every spelling of this unit a person might type.
        var acceptedSuffixes: [String] {
            switch self {
            case .percent: ["%", "percent", "pct"]
            case .points: ["pixels", "points", "pts", "px", "pt"]
            case .screenPoints: ["points", "pts", "pt", "px"]
            case .wordsPerMinute: ["words per minute", "wpm"]
            case .degrees: ["°", "deg", "degrees"]
            case .multiplier: ["×", "x", "*"]
            case .seconds: ["seconds", "second", "secs", "sec", "s"]
            case .plain: []
            }
        }
    }

    public var unit: Unit
    public var decimals: Int
    /// When true, positive values are written with a leading plus — signed ranges
    /// (tilt, pan, roll) so the field matches the detent at zero.
    public var showsPositiveSign: Bool

    public init(unit: Unit, decimals: Int = 0, showsPositiveSign: Bool = false) {
        self.unit = unit
        self.decimals = max(decimals, 0)
        self.showsPositiveSign = showsPositiveSign
    }

    public static let percent = SliderValueFormat(unit: .percent)
    public static let points = SliderValueFormat(unit: .points)
    public static let degrees = SliderValueFormat(unit: .degrees)
    public static let multiplier = SliderValueFormat(unit: .multiplier, decimals: 2)
    public static let seconds = SliderValueFormat(unit: .seconds, decimals: 1)
    public static let screenPoints = SliderValueFormat(unit: .screenPoints)
    public static let wordsPerMinute = SliderValueFormat(unit: .wordsPerMinute)

    public static func percent(signed: Bool, decimals: Int = 0) -> SliderValueFormat {
        SliderValueFormat(unit: .percent, decimals: decimals, showsPositiveSign: signed)
    }

    public static func degrees(signed: Bool) -> SliderValueFormat {
        SliderValueFormat(unit: .degrees, showsPositiveSign: signed)
    }

    /// One arrow-key press, in stored units: one of whatever the field shows.
    public var step: Double {
        pow(10, Double(-decimals)) / unit.displayScale
    }

    /// The stored value, written the way the field shows it (including the suffix).
    public func string(for value: Double) -> String {
        let shown = value * unit.displayScale
        let number = Self.withoutNegativeZero(String(format: "%.\(decimals)f", shown))
        let isPositive = number.first != "-" && number.contains { $0 != "0" && $0 != "." }
        let sign = showsPositiveSign && isPositive ? "+" : ""
        return sign + number + unit.suffix
    }

    /// "-0" is what rounding a tiny negative number produces, and it reads as a value that is
    /// somehow not zero. Zero has no sign.
    private static func withoutNegativeZero(_ number: String) -> String {
        guard number.hasPrefix("-"), !number.contains(where: { $0 != "-" && $0 != "0" && $0 != "." }) else {
            return number
        }
        return String(number.dropFirst())
    }

    /// The number alone, for the focused value field — the suffix is already implied.
    public func editingString(for value: Double) -> String {
        Self.withoutNegativeZero(String(format: "%.\(decimals)f", value * unit.displayScale))
    }

    /// A typed string as a stored value, or nil if it is not a number.
    ///
    /// Accepts the unit's own suffix in any of its spellings, any other unit's suffix (a
    /// stray "px" in a per-cent field is a slip, not an instruction), a leading sign, and a
    /// comma as the decimal separator — which is what a keyboard in most of the world
    /// produces.
    public func value(from text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Longest first, so "percent" is not left as "ercent" after stripping "p".
        let suffixes = Unit.allSuffixes.sorted { $0.count > $1.count }
        for suffix in suffixes where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let shown = Double(trimmed), shown.isFinite else { return nil }
        return shown / unit.displayScale
    }

    /// The value stepped by one arrow-key press.
    ///
    /// One unit of whatever the field shows, so a per-cent field steps by a whole per cent
    /// rather than by a hundredth of one. Multipliers with two decimals step by 0.01×. A
    /// slider with its own `stepSize` steps by that instead, in stored units.
    public func stepped(_ value: Double, by steps: Int, stepSize: Double? = nil) -> Double {
        value + Double(steps) * (stepSize ?? step)
    }
}

extension SliderValueFormat.Unit {
    /// Every suffix of every unit, for stripping.
    static var allSuffixes: [String] {
        [percent, points, screenPoints, wordsPerMinute, degrees, multiplier, seconds]
            .flatMap(\.acceptedSuffixes)
    }
}
