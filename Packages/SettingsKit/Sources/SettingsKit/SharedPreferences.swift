import CoreFoundation
import Foundation

/// The agent's preferences, read from any Kadr process (docs/17 §5 theme 6).
///
/// Settings are written by the agent into its own domain, `app.kadr.Kadr`. The editor is a
/// separate app (`app.kadr.Kadr.Editor`), so `UserDefaults.standard` there is a different
/// domain, and reading an agent key from it silently returns the default (T-ED-3). Every
/// cross-process read of an agent-owned key goes through this type instead.
///
/// `CFPreferencesCopyAppValue` rather than `UserDefaults(suiteName:)`: a suite adds to the
/// search list; it is not a direct read of another application's standard domain.
public struct SharedPreferences: Sendable {
    /// The agent's bundle identifier, which is also its preferences domain.
    public static let agentDomain = "app.kadr.Kadr"

    public let domain: String

    /// - Parameter domain: the agent's domain. Tests pass a throwaway domain so they
    ///   exercise the same real `CFPreferences` path without touching the user's settings.
    public init(domain: String = SharedPreferences.agentDomain) {
        self.domain = domain
    }

    /// The stored flag, or the key's default when it is missing or not a Boolean.
    public subscript(key: SettingKey<Bool>) -> Bool {
        let raw = CFPreferencesCopyAppValue(key.name as CFString, domain as CFString)
        if let flag = raw as? Bool {
            return flag
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return key.defaultValue
    }

    // MARK: - The agent keys other processes read

    public var lockCanvasByDefault: Bool {
        self[SettingKeys.lockCanvasByDefault]
    }

    public var objectShadowsEnabled: Bool {
        self[SettingKeys.objectShadowsEnabled]
    }

    public var keepOriginalWhenAnnotating: Bool {
        self[SettingKeys.keepOriginalWhenAnnotating]
    }

    public var writesSidecarOnSave: Bool {
        self[SettingKeys.writesSidecarOnSave]
    }

    public var convertExportsToSRGB: Bool {
        self[SettingKeys.convertExportsToSRGB]
    }
}
