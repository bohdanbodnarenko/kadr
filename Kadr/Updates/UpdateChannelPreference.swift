import Foundation

/// Whether Kadr offers beta builds as well as releases (docs/17 T-REL-4).
///
/// Sparkle reads every item in the appcast and skips the ones tagged with a channel the
/// updater did not allow, so a single feed serves both groups. The default follows the
/// build: a pre-1.0 dogfood build starts on the beta channel, because that is where its
/// next build will be published, and a release starts off it. Once the user flips the
/// switch their answer is kept.
nonisolated struct UpdateChannelPreference {
    static let key = "com.bohdanbodnarenko.kadr.receiveBetaUpdates"
    /// The channel name in `<sparkle:channel>`; `Scripts/update-appcast.sh --channel beta`
    /// writes the same string.
    static let betaChannel = "beta"

    let defaults: UserDefaults
    /// What an untouched install gets.
    let defaultValue: Bool

    init(defaults: UserDefaults, build: BuildIdentity) {
        self.defaults = defaults
        defaultValue = build.isPrerelease
    }

    var receivesBetaBuilds: Bool {
        get {
            defaults.object(forKey: Self.key) as? Bool ?? defaultValue
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.key)
        }
    }

    /// The set `SPUUpdaterDelegate.allowedChannels(for:)` returns. Items with no channel
    /// are always offered; an empty set means "releases only".
    var allowedChannels: Set<String> {
        receivesBetaBuilds ? [Self.betaChannel] : []
    }
}
