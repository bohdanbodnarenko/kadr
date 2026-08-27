import AnnotationModel
import Foundation
import Testing
@testable import EditorUI

@Suite("Beautify presets")
struct BeautifyPresetStoreTests {
    @Test("Saved looks round-trip through a throwaway defaults suite")
    func roundTrip() {
        let store = BeautifyPresetStore(store: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        store.add(name: "Poster", spec: .twitter)
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "Poster")
        #expect(loaded[0].spec.aspect == .sixteenNine)
        store.remove(id: loaded[0].id)
        #expect(store.load().isEmpty)
    }
}
