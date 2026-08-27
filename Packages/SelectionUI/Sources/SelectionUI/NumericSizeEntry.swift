import CoreGraphics

/// "Type numbers to set exact W×H" from docs/03 §1.1.
///
/// A tiny parser rather than a text field: the overlay has no controls, so digits typed
/// anywhere on it build up a size. Separated out and tested on its own because entry
/// rules — what starts entry, what commits it, what backspace does — are exactly the
/// sort of thing that rots quietly inside a view.
public struct NumericSizeEntry: Equatable, Sendable {
    public enum Field: Equatable, Sendable {
        case width
        case height
    }

    public private(set) var widthText = ""
    public private(set) var heightText = ""
    public private(set) var field: Field = .width

    /// Characters that move entry from the width to the height.
    private static let separators: Set<Character> = ["x", "X", "×", ",", " ", "\t"]
    /// Nobody is selecting a region 100,000 points wide.
    private static let maximumDigits = 5

    public init() {}

    /// Whether anything has been typed yet.
    public var isEmpty: Bool {
        widthText.isEmpty && heightText.isEmpty
    }

    /// Feeds one character in. Returns false if the character means nothing here, so the
    /// caller can pass it on to whatever else handles keys.
    @discardableResult
    public mutating func accept(_ character: Character) -> Bool {
        if character.isNumber {
            switch field {
            case .width where widthText.count < Self.maximumDigits:
                widthText.append(character)
            case .height where heightText.count < Self.maximumDigits:
                heightText.append(character)
            default:
                return false
            }
            return true
        }

        if Self.separators.contains(character) {
            // A separator before any digits is meaningless; ignore it rather than
            // stranding entry in the height field with no width.
            guard !widthText.isEmpty else { return false }
            field = .height
            return true
        }

        return false
    }

    /// Backspace. Deletes within the current field, then falls back to the previous one.
    @discardableResult
    public mutating func deleteBackward() -> Bool {
        switch field {
        case .height where !heightText.isEmpty:
            heightText.removeLast()
        case .height:
            field = .width
            if !widthText.isEmpty {
                widthText.removeLast()
            }
        case .width where !widthText.isEmpty:
            widthText.removeLast()
        case .width:
            return false
        }
        return true
    }

    public mutating func reset() {
        widthText = ""
        heightText = ""
        field = .width
    }

    /// The size typed so far, if it is complete and usable.
    ///
    /// A width with no height is treated as a square, which is what "type 400 and press
    /// Enter" should obviously do.
    public var size: CGSize? {
        guard let width = Double(widthText), width > 0 else { return nil }
        guard !heightText.isEmpty else { return CGSize(width: width, height: width) }
        guard let height = Double(heightText), height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// What to show on the overlay while typing.
    public var displayText: String {
        let width = widthText.isEmpty ? "–" : widthText
        return switch field {
        case .width: "\(width) × …"
        case .height: "\(width) × \(heightText.isEmpty ? "…" : heightText)"
        }
    }
}
