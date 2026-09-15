import AnnotationModel
import Foundation
import Testing
@testable import EditorUI

@Suite("Style memory store")
struct StyleMemoryStoreTests {
    @Test("A remembered style round-trips")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "StyleMemoryStoreTests"))
        defaults.removePersistentDomain(forName: "StyleMemoryStoreTests")
        defer { defaults.removePersistentDomain(forName: "StyleMemoryStoreTests") }

        var memory = StyleMemory()
        memory.remember(StrokeStyle(color: .black, width: 9), for: .arrow)
        memory.lastArrowHead = .open
        StyleMemoryStore.save(memory, to: defaults)

        let loaded = StyleMemoryStore.load(from: defaults)
        #expect(loaded.stroke(for: .arrow).width == 9)
        #expect(loaded.stroke(for: .arrow).color == .black)
        #expect(loaded.lastArrowHead == .open)
    }

    @Test("An older blob without newer keys still loads")
    func olderBlobDecodes() throws {
        let defaults = try #require(UserDefaults(suiteName: "StyleMemoryStoreTests-old"))
        defaults.removePersistentDomain(forName: "StyleMemoryStoreTests-old")
        defer { defaults.removePersistentDomain(forName: "StyleMemoryStoreTests-old") }

        let encoded = try JSONEncoder().encode(StyleMemory())
        defaults.set(encoded, forKey: StyleMemoryStore.defaultsKey)

        let loaded = StyleMemoryStore.load(from: defaults)
        #expect(loaded.lastArrowHead == .filled)
        #expect(loaded.lastCounterSize == .default)
    }
}
