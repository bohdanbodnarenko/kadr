import AnnotationModel
import Foundation

/// User-saved beautify looks, stored locally in the editor process (docs/03 §3 P2).
///
/// EditorUI cannot import SettingsKit (sibling packages), so this is a small UserDefaults
/// list rather than an AppSettings key.
struct BeautifyPresetStore {
    struct Saved: Codable, Hashable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var spec: BeautifySpec
    }

    private let store: UserDefaults
    private let key = "editor.beautify.userPresets"

    init(store: UserDefaults = .standard) {
        self.store = store
    }

    func load() -> [Saved] {
        guard let data = store.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: data)) ?? []
    }

    func save(_ presets: [Saved]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        store.set(data, forKey: key)
    }

    func add(name: String, spec: BeautifySpec) {
        var presets = load()
        presets.append(Saved(id: UUID(), name: name, spec: spec))
        save(presets)
    }

    func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }
}
