import Foundation
import Security

/// Where automation consent is kept (docs/18 OUT-13).
///
/// Not in the preferences domain: `defaults write` from any process could flip the switch
/// and add itself as an allowed app, then drive Kadr's Screen Recording grant. The Keychain
/// item is written by Kadr and readable only through it.
public protocol AutomationConsentStorage: AnyObject {
    func load() -> AutomationConsentSnapshot?
    func save(_ snapshot: AutomationConsentSnapshot)
}

/// Everything consent remembers, as one value.
public struct AutomationConsentSnapshot: Codable, Equatable, Sendable {
    public var allowsOtherApps: Bool
    public var decisions: [String: AutomationConsent.Decision]
    public var names: [String: String]

    public init(
        allowsOtherApps: Bool = false,
        decisions: [String: AutomationConsent.Decision] = [:],
        names: [String: String] = [:]
    ) {
        self.allowsOtherApps = allowsOtherApps
        self.decisions = decisions
        self.names = names
    }
}

/// A generic-password Keychain item holding the snapshot as JSON.
public final class KeychainConsentStorage: AutomationConsentStorage {
    private let service: String
    private let account = "consent"

    public init(service: String = "com.bohdanbodnarenko.kadr.automation-consent") {
        self.service = service
    }

    public func load() -> AutomationConsentSnapshot? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(AutomationConsentSnapshot.self, from: data)
    }

    public func save(_ snapshot: AutomationConsentSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(baseQuery as CFDictionary, update) == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Kadr automation consent"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Removes the item, for Reset All Settings and Remove All Data.
    public func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Consent kept in memory only, for tests and previews.
public final class InMemoryConsentStorage: AutomationConsentStorage {
    public private(set) var snapshot: AutomationConsentSnapshot?

    public init(_ snapshot: AutomationConsentSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() -> AutomationConsentSnapshot? {
        snapshot
    }

    public func save(_ snapshot: AutomationConsentSnapshot) {
        self.snapshot = snapshot
    }
}
