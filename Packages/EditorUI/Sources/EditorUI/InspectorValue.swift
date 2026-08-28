import Foundation

/// How an inspector value is written and read back (docs/09 U1.5).
///
/// The point of typing into a slider is that the user can say what they mean exactly, and
/// what they type is what they see: a field showing "45%" has to accept "45%". It also has
/// to accept "45", because nobody retypes the suffix, and "0.45" is a different number that
/// somebody will eventually try — so the parser has to be forgiving without being a guess.
///
/// Kept apart from the control because parsing is where this goes wrong and a pure function
/// is where that can be caught.
public struct InspectorValueFormat: Equatable, Sendable {
    /// What the number means, which decides both the suffix and the display scale.
    public enum Unit: String, Equatable, Sendable {
        /// Stored 0…1, shown 0…100 with a per-cent sign.
        case percent
        /// Shown as-is, in points.
        case points
        /// Shown as-is, in degrees.
        case degrees
        /// Shown as-is, with a multiplication sign.
        case multiplier
        /// A bare number.
        case plain

        var suffix: String {
            switch self {
            case .percent: "%"
            case .points: " px"
            case .degrees: "°"
            case .multiplier: "×"
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
            case .points: ["px", "pt", "points", "pixels"]
            case .degrees: ["°", "deg", "degrees"]
            case .multiplier: ["×", "x", "*"]
            case .plain: []
            }
        }
    }

    public var unit: Unit
    public var decimals: Int

    public init(unit: Unit, decimals: Int = 0) {
        self.unit = unit
        self.decimals = max(decimals, 0)
    }

    public static let percent = InspectorValueFormat(unit: .percent)
    public static let points = InspectorValueFormat(unit: .points)
    public static let degrees = InspectorValueFormat(unit: .degrees)
    public static let multiplier = InspectorValueFormat(unit: .multiplier, decimals: 2)

    /// The stored value, written the way the field shows it.
    public func string(for value: Double) -> String {
        let shown = value * unit.displayScale
        return String(format: "%.\(decimals)f", shown) + unit.suffix
    }

    /// A typed string as a stored value, or nil if it is not a number.
    ///
    /// Accepts the unit's own suffix in any of its spellings, any other unit's suffix (a
    /// stray "px" in a per-cent field is a slip, not an instruction), a leading sign, and a
    /// comma as the decimal separator — which is what a keyboard in most of the world
    /// produces.
    public func value(from text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    /// rather than by a hundredth of one.
    public func stepped(_ value: Double, by steps: Int) -> Double {
        value + Double(steps) / unit.displayScale
    }
}

extension InspectorValueFormat.Unit {
    /// Every suffix of every unit, for stripping.
    static var allSuffixes: [String] {
        [percent, points, degrees, multiplier].flatMap(\.acceptedSuffixes)
    }
}
