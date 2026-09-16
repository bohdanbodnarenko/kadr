import Foundation

/// Whether Kadr checks for updates on its own — the user's answer, kept apart from
/// Sparkle's (PRD §9, docs/10 R2.3).
///
/// Kadr turns Sparkle's own scheduler off and asks `NSBackgroundActivityScheduler` for a
/// coalesced daily check instead. Turning it off means writing `false` to Sparkle's
/// `SUEnableAutomaticChecks`, so that key stops meaning "the user wants checks" the moment
/// the updater first starts — and it is the key the preference used to fall back to when
/// Kadr's own had never been written. From the second launch on, everybody who had never
/// touched the switch read `false` and got no automatic checks at all.
///
/// Kadr's key is now written on first use, and Sparkle's is never consulted: nothing in
/// Kadr ever showed Sparkle's permission prompt (writing `SUEnableAutomaticChecks` is what
/// suppresses it), so any value there was put there by Kadr, not chosen by the user.
struct UpdateCheckPreference {
    /// Kadr's own key.
    static let key = "app.kadr.automaticUpdateChecks"
    /// Sparkle's key, which Kadr writes `false` to and never reads.
    static let sparkleKey = "SUEnableAutomaticChecks"
    /// On by default, with a visible switch (PRD §9).
    static let defaultValue = true

    let defaults: UserDefaults

    /// The user's preference, persisting the default the first time it is asked for.
    var isEnabled: Bool {
        get {
            migrateIfNeeded()
            return defaults.bool(forKey: Self.key)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.key)
        }
    }

    /// Writes the default if Kadr's key has never been written.
    ///
    /// Deliberately ignores whatever Sparkle's key holds — see the type's documentation.
    func migrateIfNeeded() {
        guard defaults.object(forKey: Self.key) == nil else { return }
        defaults.set(Self.defaultValue, forKey: Self.key)
    }
}
