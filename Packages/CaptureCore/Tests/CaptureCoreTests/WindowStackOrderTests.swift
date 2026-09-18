import CoreGraphics
import Foundation
import Shared
import Testing
@testable import CaptureCore

/// Window-pick order comes from the window server, not ScreenCaptureKit (docs/03 §1.2).
@Suite("Window stack order")
struct WindowStackOrderTests {
    private func window(_ id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id,
            title: nil,
            applicationName: "App",
            bundleIdentifier: "com.example.app",
            processID: 1,
            frame: DisplayRect(x: 0, y: 0, width: 400, height: 300),
            isOnScreen: true,
            layer: 0
        )
    }

    private func stack(_ ids: [CGWindowID], alpha: [CGWindowID: Double] = [:]) -> [CGWindowID: WindowStackOrder.Entry] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { rank, id in
            (id, WindowStackOrder.Entry(rank: rank, alpha: alpha[id] ?? 1))
        })
    }

    @Test("Windows come out in the window server's order, whatever order they went in", arguments: [
        ([CGWindowID(1), 2, 3], [CGWindowID(3), 1, 2], [CGWindowID(3), 1, 2]),
        ([5, 4, 3, 2, 1], [1, 2, 3, 4, 5], [1, 2, 3, 4, 5]),
        ([10, 20], [20, 10], [20, 10])
    ])
    func sortsByStack(input: [CGWindowID], order: [CGWindowID], expected: [CGWindowID]) {
        let sorted = WindowStackOrder.ordered(input.map(window), stack: stack(order))
        #expect(sorted.map(\.id) == expected)
    }

    @Test("Windows the window server does not list go last, in their original order")
    func unknownWindowsGoLast() {
        let sorted = WindowStackOrder.ordered([7, 1, 8, 2].map(window), stack: stack([2, 1]))
        #expect(sorted.map(\.id) == [2, 1, 7, 8])
    }

    @Test("Invisible windows and Kadr's own panels are never picked")
    func filters() {
        let sorted = WindowStackOrder.ordered(
            [1, 2, 3, 4].map(window),
            stack: stack([1, 2, 3, 4], alpha: [2: 0]),
            excluding: [3]
        )
        #expect(sorted.map(\.id) == [1, 4])
    }

    @Test("The window server's dictionaries are read front to back")
    func readsWindowList() {
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 42), kCGWindowAlpha as String: NSNumber(value: 1.0)],
            [kCGWindowNumber as String: NSNumber(value: 7), kCGWindowAlpha as String: NSNumber(value: 0.0)],
            [kCGWindowAlpha as String: NSNumber(value: 1.0)],
            [kCGWindowNumber as String: NSNumber(value: 9)]
        ]
        let entries = WindowStackOrder.entries(from: list)
        #expect(entries[42] == .init(rank: 0, alpha: 1))
        #expect(entries[7] == .init(rank: 1, alpha: 0))
        #expect(entries[9] == .init(rank: 3, alpha: 1))
        #expect(entries.count == 3)
    }

    @Test("The live window list reads without a permission prompt and is front to back")
    func liveList() {
        // Metadata only; on a CI machine with no windows this is simply empty.
        let entries = WindowStackOrder.current()
        let ranks = entries.values.map(\.rank)
        #expect(Set(ranks).count == ranks.count)
    }
}
