import CoreGraphics
import Foundation
import Testing
@testable import Kadr

/// docs/18 §4.2 P3: the island reopens where the user left it.
@Suite("Island placement memory")
struct IslandPlacementMemoryTests {
    private func defaults() -> UserDefaults {
        let name = "IslandPlacementMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let size = CGSize(width: 400, height: 60)

    @Test("Nothing remembered means no frame")
    func empty() {
        #expect(IslandPlacementMemory.frame(for: size, in: CGRect(x: 0, y: 0, width: 1000, height: 800), defaults: defaults()) == nil)
    }

    @Test("A spot carries proportionally to another screen", arguments: [
        (CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 300, y: 370, width: 400, height: 60)),
        (CGRect(x: 1000, y: 0, width: 2000, height: 1600), CGRect(x: 1800, y: 770, width: 400, height: 60))
    ])
    func proportional(visible: CGRect, expected: CGRect) {
        let store = defaults()
        IslandPlacementMemory.remember(
            CGRect(x: 300, y: 370, width: 400, height: 60),
            in: CGRect(x: 0, y: 0, width: 1000, height: 800),
            defaults: store
        )
        #expect(IslandPlacementMemory.frame(for: size, in: visible, defaults: store) == expected)
    }

    @Test("A spot near an edge stays wholly on a smaller screen")
    func clampedToScreen() throws {
        let store = defaults()
        IslandPlacementMemory.remember(
            CGRect(x: 1580, y: 10, width: 400, height: 60),
            in: CGRect(x: 0, y: 0, width: 2000, height: 1000),
            defaults: store
        )
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = try #require(IslandPlacementMemory.frame(for: size, in: visible, defaults: store))
        #expect(visible.contains(frame))
    }
}
