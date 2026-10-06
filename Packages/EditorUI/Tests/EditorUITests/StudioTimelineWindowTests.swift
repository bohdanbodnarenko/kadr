import CoreGraphics
import Testing
@testable import EditorUI

/// Drawing only the filmstrip under the viewport (docs/18 STU-15).
@Suite("Studio timeline window")
struct StudioTimelineWindowTests {
    @Test("The window covers the viewport and one viewport either side", arguments: [
        (CGFloat(0), CGFloat(0) ... CGFloat(1064)),
        (-1000, 460 ... 2024),
        (-1030, 524 ... 2088)
    ])
    func visibleRange(leading: CGFloat, expected: ClosedRange<CGFloat>) {
        #expect(StudioTimelineWindow.visibleRange(origin: leading, viewportWidth: 500) == expected)
    }

    @Test("Tile indices cover the visible stretch in whole chunks", arguments: [
        (nil as ClosedRange<CGFloat>?, 0 ..< 100),
        (0 ... 360, 0 ..< 32),
        (1200 ... 1800, 32 ..< 64),
        (-500 ... -10, 0 ..< 0),
        (3600 ... 4000, 0 ..< 0)
    ])
    func tileIndices(visible: ClosedRange<CGFloat>?, expected: Range<Int>) {
        // 100 tiles of 36 points.
        #expect(StudioTimelineWindow.tileIndices(visible: visible, width: 3600, count: 100) == expected)
    }

    @Test("A windowed lane keeps natural tile width however long it is")
    func windowedCount() {
        #expect(StudioFilmstrip.tileCount(forWidth: 360_000, windowed: true) == 10_000)
        #expect(StudioFilmstrip.tileCount(forWidth: 360_000) == StudioFilmstrip.maximumTiles)
    }
}
