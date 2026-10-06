import Foundation

/// A zoom or speed factor as people read it: "1.5×", with the decimal separator of the
/// reader's locale ("1,5×" in Ukrainian or German).
///
/// `String(format: "%.1f×")` always wrote a full stop, in every locale (docs/18 X-4).
enum StudioMultiplier {
    static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}
