import AnnotationModel
import Foundation

/// Favourite annotation colours, persisted across editor sessions (CleanShot §8.3).
///
/// Stored in `UserDefaults` rather than SettingsKit: the editor process must not
/// depend on SettingsKit (docs/04 §2).
public struct EditorUserPalette: Equatable, Sendable {
    public static let capacity = 8
    public static let defaultsKey = "app.kadr.editor.userPalette"

    public private(set) var colors: [AnnotationColor]

    public init(colors: [AnnotationColor] = []) {
        self.colors = Array(colors.prefix(Self.capacity))
    }

    public static func load(from defaults: UserDefaults = .standard) -> EditorUserPalette {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([AnnotationColor].self, from: data)
        else {
            return EditorUserPalette()
        }
        return EditorUserPalette(colors: decoded)
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(colors) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func contains(_ color: AnnotationColor) -> Bool {
        colors.contains { $0.isClose(to: color) }
    }

    /// Built-in swatches already sit in the strip; favourites are for custom colours.
    public func canAdd(_ color: AnnotationColor) -> Bool {
        guard !contains(color) else { return false }
        return !AnnotationColor.annotationSwatches.contains { $0.isClose(to: color) }
    }

    @discardableResult
    public mutating func add(_ color: AnnotationColor) -> Bool {
        guard canAdd(color) else { return false }
        var next = colors
        if next.count >= Self.capacity {
            next.removeFirst()
        }
        next.append(color)
        colors = next
        return true
    }

    public mutating func remove(_ color: AnnotationColor) {
        colors.removeAll { $0.isClose(to: color) }
    }
}

extension AnnotationColor {
    func isClose(to other: AnnotationColor) -> Bool {
        abs(red - other.red) < 0.02
            && abs(green - other.green) < 0.02
            && abs(blue - other.blue) < 0.02
            && abs(alpha - other.alpha) < 0.02
    }
}
