import AnnotationModel
import Foundation
import os
import Shared

/// User-saved looks, kept locally in the editor process (docs/09 U1.5).
///
/// EditorUI cannot import SettingsKit (sibling packages, docs/04 §2), so this is a small
/// `UserDefaults` list rather than an `AppSettings` key.
///
/// It keeps a second copy under a different key, written *before* the primary. That is not
/// belt and braces for its own sake: presets are the only thing in the editor a user
/// authors and cannot recreate from the capture, and the failure mode that loses them is a
/// half-written primary — an encode that succeeds and a decode that later does not. With a
/// recovery copy the worst case is losing the newest preset instead of all of them
/// (docs/08 §2.6).
public struct StylePresetStore {
    private let store: UserDefaults
    private let logger = KadrLog.logger(.app)

    private let key = "editor.style.presets"
    private let recoveryKey = "editor.style.presets.recovery"

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    /// The user's presets, or the recovery copy if the primary cannot be read.
    public func load() -> [StylePreset] {
        if let presets = decode(store.data(forKey: key)) {
            return presets
        }
        if let recovered = decode(store.data(forKey: recoveryKey)) {
            logger.error("Style presets were unreadable; restored the recovery copy")
            // Put it back, so the next launch does not have to recover again.
            save(recovered)
            return recovered
        }
        return []
    }

    public func save(_ presets: [StylePreset]) {
        guard let data = try? JSONEncoder().encode(presets) else {
            logger.error("Could not encode the style presets; leaving what was stored")
            return
        }
        // Recovery first: if the process dies between the two writes, the copy is the
        // *older* complete list rather than a torn newer one.
        store.set(store.data(forKey: key) ?? data, forKey: recoveryKey)
        store.set(data, forKey: key)
    }

    @discardableResult
    public func addImported(_ preset: StylePreset) -> [StylePreset] {
        var presets = load()
        var name = preset.name
        var suffix = 2
        let taken: (String) -> Bool = { candidate in
            presets.contains { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
                || StylePreset.builtIn.contains { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        while taken(name) {
            name = "\(preset.name) \(suffix)"
            suffix += 1
        }
        var copy = preset
        copy.id = UUID()
        copy.name = name
        presets.append(copy)
        save(presets)
        return presets
    }

    @discardableResult
    public func add(_ preset: StylePreset) -> [StylePreset] {
        var presets = load()
        // Saving over a name replaces it, which is what someone who types the same name
        // twice means — and stops the list filling with "Hero Lean" four times.
        presets.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
        presets.append(preset)
        save(presets)
        return presets
    }

    @discardableResult
    public func remove(id: UUID) -> [StylePreset] {
        let presets = load().filter { $0.id != id }
        save(presets)
        return presets
    }

    /// Built-ins first, then the user's own — the order the inspector shows them in.
    public func all() -> [StylePreset] {
        StylePreset.builtIn + load()
    }

    private func decode(_ data: Data?) -> [StylePreset]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([StylePreset].self, from: data)
    }
}
