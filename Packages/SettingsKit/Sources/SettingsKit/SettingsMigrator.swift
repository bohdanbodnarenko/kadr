import Foundation
import Shared

/// Versioned migration of the defaults store (docs/04 §9).
///
/// Each step moves the store from one schema version to the next; adding a setting
/// needs no step, renaming or re-typing one does. A store stamped with a *newer*
/// version than this build knows about is left untouched — downgrading must not
/// silently discard preferences written by a later version.
public enum SettingsMigrator {
    /// The schema this build writes.
    public static let currentVersion = 1

    /// A single forward step: takes a store at `fromVersion` to `fromVersion + 1`.
    struct Step {
        let fromVersion: Int
        let apply: @Sendable (UserDefaults) -> Void
    }

    /// Version 0 is "never written by Kadr". There is nothing to move yet, so the
    /// first step only stamps the version; it exists so the machinery is exercised
    /// and tested before the first real migration needs it.
    static let steps: [Step] = [
        Step(fromVersion: 0, apply: { _ in })
    ]

    @discardableResult
    public static func migrate(_ store: UserDefaults) -> Int {
        var version = store[SettingKeys.schemaVersion]

        guard version <= currentVersion else {
            KadrLog.logger(.settings).warning(
                "Defaults were written by a newer Kadr (schema \(version, privacy: .public)); leaving them alone"
            )
            return version
        }

        while version < currentVersion, let step = steps.first(where: { $0.fromVersion == version }) {
            step.apply(store)
            version = step.fromVersion + 1
            store[SettingKeys.schemaVersion] = version
        }

        return version
    }
}
