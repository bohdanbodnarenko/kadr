import Foundation
import Observation

/// Who may drive Kadr through `kadr://` (docs/03 §8.4, docs/17 T-OUT-12).
///
/// A URL can come from any app — a web page is one browser prompt away from opening one,
/// and a browser can be told to "always allow" it. Without a gate that let anything take
/// silent screenshots, start the microphone, or OCR any readable file through Kadr's own
/// Screen Recording grant. So:
///
/// * the switch **Allow other apps to control Kadr** is off by default;
/// * with it on, each app is asked once, and the answer is remembered per app;
/// * a sender that cannot be identified is asked every time, since there is nothing to
///   remember the answer against;
/// * Kadr's own processes — the editor, the bundled CLI — are always allowed.
///
/// Remembered per bundle identifier *and* signing team, so an app cannot inherit another
/// app's permission by copying its bundle identifier.
@MainActor
@Observable
public final class AutomationConsent {
    public enum Decision: String, Codable, Sendable {
        case allowed
        case denied
    }

    /// Where a `kadr://` request came from.
    public enum Sender: Equatable, Sendable {
        /// Kadr's own signed code.
        case kadr
        /// An app, by bundle identifier, its signing team (nil when unsigned) and name.
        case app(bundleID: String, teamID: String?, name: String)
        /// Something with no bundle to name — `open` in a script, a daemon.
        case unidentified(name: String?)
    }

    public enum Verdict: Equatable, Sendable {
        case run
        case ask
        case refuse(RefusalReason)
    }

    public enum RefusalReason: Equatable, Sendable {
        /// "Allow other apps to control Kadr" is off.
        case notAllowed
        /// The user said no to this app before.
        case deniedBefore
    }

    /// The switch in Settings → Advanced.
    public var allowsOtherApps: Bool {
        didSet { store.set(allowsOtherApps, forKey: Self.allowsOtherAppsKey) }
    }

    /// Remembered answers, by `key(for:)`.
    public private(set) var decisions: [String: Decision]
    /// Display names for the remembered apps, for the Settings list.
    public private(set) var names: [String: String]

    private let store: UserDefaults

    static let allowsOtherAppsKey = "automation.allowsOtherApps"
    static let decisionsKey = "automation.consentDecisions"
    static let namesKey = "automation.consentNames"

    public init(store: UserDefaults = .standard) {
        self.store = store
        allowsOtherApps = store.bool(forKey: Self.allowsOtherAppsKey)
        let raw = store.dictionary(forKey: Self.decisionsKey) as? [String: String] ?? [:]
        decisions = raw.compactMapValues(Decision.init(rawValue:))
        names = store.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
    }

    /// What to do with a request from `sender`.
    public func verdict(for sender: Sender) -> Verdict {
        Self.verdict(for: sender, allowsOtherApps: allowsOtherApps, decisions: decisions)
    }

    /// The policy itself, pure so it can be tested as a table.
    public nonisolated static func verdict(
        for sender: Sender,
        allowsOtherApps: Bool,
        decisions: [String: Decision]
    ) -> Verdict {
        if case .kadr = sender {
            return .run
        }
        guard allowsOtherApps else { return .refuse(.notAllowed) }
        guard let key = key(for: sender) else { return .ask }
        switch decisions[key] {
        case .allowed: return .run
        case .denied: return .refuse(.deniedBefore)
        case nil: return .ask
        }
    }

    /// Remembers the answer for an app. An unidentified sender is not remembered.
    public func record(_ decision: Decision, for sender: Sender) {
        guard let key = Self.key(for: sender), case let .app(_, _, name) = sender else { return }
        decisions[key] = decision
        names[key] = name
        persist()
    }

    /// Forgets an app, so it is asked again next time.
    public func forget(_ key: String) {
        decisions.removeValue(forKey: key)
        names.removeValue(forKey: key)
        persist()
    }

    /// Back to first launch: other apps refused, nothing remembered. Part of Reset All
    /// Settings, which used to leave every grant in place (docs/18 SH-5).
    public func reset() {
        allowsOtherApps = false
        decisions.removeAll()
        names.removeAll()
        persist()
    }

    /// One remembered answer, for the Settings list.
    public struct RememberedApp: Equatable, Sendable {
        public let key: String
        public let name: String
        public let decision: Decision
    }

    /// The remembered apps, by name, for Settings.
    public var rememberedApps: [RememberedApp] {
        decisions
            .map { RememberedApp(key: $0.key, name: names[$0.key] ?? $0.key, decision: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public nonisolated static func key(for sender: Sender) -> String? {
        guard case let .app(bundleID, teamID, _) = sender else { return nil }
        return "\(bundleID)|\(teamID ?? "unsigned")"
    }

    private func persist() {
        store.set(decisions.mapValues(\.rawValue), forKey: Self.decisionsKey)
        store.set(names, forKey: Self.namesKey)
    }
}
