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
/// app's permission by copying its bundle identifier. Kept in the Keychain, not the
/// preferences domain, so `defaults write` cannot grant anything; and a web browser's yes
/// is never remembered, because a browser opens `kadr://` for any page it shows
/// (docs/18 OUT-13).
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
        didSet { persist() }
    }

    /// Remembered answers, by `key(for:)`.
    public private(set) var decisions: [String: Decision]
    /// Display names for the remembered apps, for the Settings list.
    public private(set) var names: [String: String]

    /// Apps whose answer is asked for every time and never remembered: web browsers, and
    /// anything else that opens URLs on behalf of content it does not control.
    public var neverRemembered: Set<String>

    private let storage: AutomationConsentStorage

    static let allowsOtherAppsKey = "automation.allowsOtherApps"
    static let decisionsKey = "automation.consentDecisions"
    static let namesKey = "automation.consentNames"

    /// Browsers Kadr knows by bundle identifier. The gate adds whatever the system lists
    /// as able to open `https:` links.
    public nonisolated static let knownBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.canary", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "app.zen-browser.zen",
        "org.chromium.Chromium"
    ]

    /// - Parameters:
    ///   - storage: where answers are kept; the Keychain unless a test says otherwise.
    ///   - legacy: the preferences domain earlier builds kept answers in. Read once, when
    ///     `storage` is still empty: the switch and any *denials* come across, but no
    ///     *allow* does — anything could have written one there.
    public init(
        storage: AutomationConsentStorage = KeychainConsentStorage(),
        legacy: UserDefaults = .standard,
        neverRemembered: Set<String> = AutomationConsent.knownBrowsers
    ) {
        self.storage = storage
        self.neverRemembered = neverRemembered
        let snapshot = storage.load() ?? Self.migrate(from: legacy, into: storage)
        allowsOtherApps = snapshot.allowsOtherApps
        decisions = snapshot.decisions
        names = snapshot.names
    }

    private static func migrate(
        from legacy: UserDefaults,
        into storage: AutomationConsentStorage
    ) -> AutomationConsentSnapshot {
        let raw = legacy.dictionary(forKey: decisionsKey) as? [String: String] ?? [:]
        let denied = raw.compactMapValues(Decision.init(rawValue:)).filter { $0.value == .denied }
        let allNames = legacy.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        let snapshot = AutomationConsentSnapshot(
            allowsOtherApps: legacy.bool(forKey: allowsOtherAppsKey),
            decisions: denied,
            names: allNames.filter { denied[$0.key] != nil }
        )
        storage.save(snapshot)
        for key in [allowsOtherAppsKey, decisionsKey, namesKey] {
            legacy.removeObject(forKey: key)
        }
        return snapshot
    }

    /// What to do with a request from `sender`.
    public func verdict(for sender: Sender) -> Verdict {
        if case let .app(bundleID, _, _) = sender, neverRemembered.contains(bundleID) {
            // A browser is asked every time, whatever an older build remembered for it.
            return allowsOtherApps ? .ask : .refuse(.notAllowed)
        }
        return Self.verdict(for: sender, allowsOtherApps: allowsOtherApps, decisions: decisions)
    }

    /// Whether an answer for `sender` would be remembered, for the prompt's wording.
    public func remembersAnswer(for sender: Sender) -> Bool {
        guard case let .app(bundleID, _, _) = sender else { return false }
        return !neverRemembered.contains(bundleID)
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

    /// Remembers the answer for an app. An unidentified sender and a browser are not.
    public func record(_ decision: Decision, for sender: Sender) {
        guard remembersAnswer(for: sender),
              let key = Self.key(for: sender), case let .app(_, _, name) = sender
        else { return }
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

    /// Forgets every answer and turns the switch off, for Reset All Settings.
    public func reset() {
        decisions.removeAll()
        names.removeAll()
        allowsOtherApps = false
    }

    private func persist() {
        storage.save(AutomationConsentSnapshot(allowsOtherApps: allowsOtherApps, decisions: decisions, names: names))
    }
}
