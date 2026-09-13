import CoreGraphics
import Testing
@testable import Shared

@Suite("Display index")
struct DisplayIndexTests {
    private let primary = ScreenRect(x: 0, y: 0, width: 1440, height: 900)
    private let secondary = ScreenRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test("Index 1 is the first screen — the primary, in AppKit order")
    func firstIsPrimary() {
        let screens = [primary, secondary]
        #expect(DisplayIndex.screen(atOneBased: 1, screens: screens) == primary)
        #expect(DisplayIndex.screen(atOneBased: 2, screens: screens) == secondary)
    }

    @Test("An index the Mac does not have is nil, not a wrap")
    func outOfRangeIsNil() {
        #expect(DisplayIndex.screen(atOneBased: 0, screens: [primary]) == nil)
        #expect(DisplayIndex.screen(atOneBased: 2, screens: [primary]) == nil)
        #expect(DisplayIndex.screen(atOneBased: -1, screens: [primary]) == nil)
    }

    @Test("Local (0,0) is the display's bottom-left in global space")
    func globalizeOrigin() {
        let local = ScreenRect(x: 100, y: 120, width: 200, height: 150)
        let global = DisplayIndex.globalize(local: local, on: secondary)
        #expect(global == ScreenRect(x: 1540, y: 120, width: 200, height: 150))
    }

    @Test("A region on the primary is unchanged when that display's origin is zero")
    func primaryIsAlreadyGlobal() {
        let local = ScreenRect(x: 10, y: 20, width: 30, height: 40)
        #expect(DisplayIndex.globalize(local: local, on: primary) == local)
    }
}
