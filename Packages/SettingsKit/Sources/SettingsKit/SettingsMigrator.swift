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
    public static let currentVersion = 3

    /// A single forward step: takes a store at `fromVersion` to `fromVersion + 1`.
    struct Step {
        let fromVersion: Int
        let apply: @Sendable (UserDefaults) -> Void
    }

    /// Version 0 is "never written by Kadr", so its step only stamps the version.
    ///
    /// Version 1 → 2 retires the `openInEditor` default action. A stored value the enum
    /// no longer knows would silently fall back to the default; mapping it explicitly
    /// keeps the user's intent — they wanted the capture in front of them, and copying
    /// to the clipboard is the closest surviving behaviour.
    static let steps: [Step] = [
        Step(fromVersion: 0, apply: { _ in }),
        Step(fromVersion: 1, apply: { store in
            let key = SettingKeys.defaultAction.name
            guard store.object(forKey: key) as? String == "openInEditor" else { return }
            store.set(DefaultCaptureAction.copyToClipboard.rawValue, forKey: key)
        }),
        Step(fromVersion: 2, apply: { store in
            // The single default action becomes a matrix (docs/09 U2.2). Migrated rather
            // than reset: the old setting is the only statement the user has ever made
            // about this, and discarding it to show them a nicer pane would be rude.
            guard AfterCaptureMatrix.read(from: store, forKey: SettingKeys.afterCapture.name) == nil
            else {
                return
            }
            let stored = store.object(forKey: SettingKeys.defaultAction.name) as? String
            let action = stored.flatMap(DefaultCaptureAction.init(rawValue:))
                ?? SettingKeys.defaultAction.defaultValue
            store[SettingKeys.afterCapture] = AfterCaptureMatrix.migrating(action)
        })
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
