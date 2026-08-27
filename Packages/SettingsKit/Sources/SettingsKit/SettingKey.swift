import Foundation

/// A value that can round-trip through `UserDefaults` under a typed key.
///
/// Conformances stay narrow on purpose: settings are primitives and string-backed
/// enums, never archived objects, so the store remains readable with `defaults read`
/// and a corrupt value can only ever fall back to its default.
public protocol SettingValue: Sendable {
    static func read(from defaults: UserDefaults, forKey key: String) -> Self?
    func write(to defaults: UserDefaults, forKey key: String)
}

extension Bool: SettingValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Int: SettingValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

extension String: SettingValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> String? {
        defaults.object(forKey: key) as? String
    }

    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(self, forKey: key)
    }
}

/// String-backed enums get their conformance for free; an unknown raw value reads as
/// `nil` and therefore falls back to the key's default rather than trapping.
public extension SettingValue where Self: RawRepresentable, Self.RawValue == String {
    static func read(from defaults: UserDefaults, forKey key: String) -> Self? {
        (defaults.object(forKey: key) as? String).flatMap(Self.init(rawValue:))
    }

    func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(rawValue, forKey: key)
    }
}

/// A `UserDefaults` key with its type and default value attached.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public extension UserDefaults {
    subscript<Value>(key: SettingKey<Value>) -> Value {
        get { Value.read(from: self, forKey: key.name) ?? key.defaultValue }
        set { newValue.write(to: self, forKey: key.name) }
    }

    /// Whether the user has ever set this key, as opposed to inheriting its default.
    func hasValue(for key: SettingKey<some Any>) -> Bool {
        object(forKey: key.name) != nil
    }
}
