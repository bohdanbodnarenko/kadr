import Foundation
import os
import Shared
import StudioSession

/// User-saved studio looks, kept locally in the editor process (docs/09 U3.5).
///
/// Same recovery pattern as `StylePresetStore`: presets are the only studio chrome a user
/// authors and cannot recreate from the footage, so a torn primary write must not wipe
/// the library.
public struct StudioPresetStore {
    private struct Library: Codable {
        var presets: [StudioPreset]
        var defaultID: UUID?
    }

    private let store: UserDefaults
    private let logger = KadrLog.logger(.app)
    private let key = "studio.style.presets"
    private let recoveryKey = "studio.style.presets.recovery"

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    public func load() -> [StudioPreset] {
        library().presets
    }

    public func defaultID() -> UUID? {
        library().defaultID
    }

    public func defaultPreset() -> StudioPreset? {
        let loaded = library()
        guard let id = loaded.defaultID else { return nil }
        return loaded.presets.first { $0.id == id } ?? StudioPreset.builtIn.first { $0.id == id }
    }

    public func all() -> [StudioPreset] {
        StudioPreset.builtIn + load()
    }

    @discardableResult
    public func add(_ preset: StudioPreset) -> [StudioPreset] {
        var loaded = library()
        loaded.presets.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
        loaded.presets.append(preset)
        save(loaded)
        return loaded.presets
    }

    @discardableResult
    public func remove(id: UUID) -> [StudioPreset] {
        var loaded = library()
        loaded.presets.removeAll { $0.id == id }
        if loaded.defaultID == id {
            loaded.defaultID = nil
        }
        save(loaded)
        return loaded.presets
    }

    public func setDefault(id: UUID?) {
        var loaded = library()
        loaded.defaultID = id
        save(loaded)
    }

    private func library() -> Library {
        if let loaded = decode(store.data(forKey: key)) {
            return loaded
        }
        if let recovered = decode(store.data(forKey: recoveryKey)) {
            logger.error("Studio presets were unreadable; restored the recovery copy")
            save(recovered)
            return recovered
        }
        return Library(presets: [], defaultID: nil)
    }

    private func save(_ library: Library) {
        guard let data = try? JSONEncoder().encode(library) else {
            logger.error("Could not encode the studio presets; leaving what was stored")
            return
        }
        store.set(store.data(forKey: key) ?? data, forKey: recoveryKey)
        store.set(data, forKey: key)
    }

    private func decode(_ data: Data?) -> Library? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Library.self, from: data)
    }
}
