import CoreGraphics
import Testing
@testable import Shared

/// A 1440-point-tall primary display, the flip axis for every case below.
private let space = GlobalCoordinateSpace(primaryDisplayHeight: 1440)

/// The built-in Retina display: origin at the global origin in both systems.
private let builtIn = DisplayGeometry(
    displayID: 1,
    frame: DisplayRect(x: 0, y: 0, width: 2560, height: 1440),
    scale: .retina
)

/// A 1× display sitting directly above the built-in one, so its display-space y is
/// negative — the arrangement that breaks naive flip maths.
private let above = DisplayGeometry(
    displayID: 2,
    frame: DisplayRect(x: 0, y: -1080, width: 1920, height: 1080),
    scale: .oneToOne
)

/// A 1× display to the left of the built-in one, so its display-space x is negative.
private let left = DisplayGeometry(
    displayID: 3,
    frame: DisplayRect(x: -1920, y: 0, width: 1920, height: 1080),
    scale: .oneToOne
)

@Suite("Screen space to display space")
struct CoordinateFlipTests {
    struct Case: Sendable {
        let name: String
        let screen: ScreenRect
        let display: DisplayRect
    }

    static let cases: [Case] = [
        Case(
            name: "bottom-left corner of the primary display",
            screen: ScreenRect(x: 0, y: 0, width: 100, height: 100),
            display: DisplayRect(x: 0, y: 1340, width: 100, height: 100)
        ),
        Case(
            name: "top-left corner of the primary display",
            screen: ScreenRect(x: 0, y: 1340, width: 100, height: 100),
            display: DisplayRect(x: 0, y: 0, width: 100, height: 100)
        ),
        Case(
            name: "the whole primary display",
            screen: ScreenRect(x: 0, y: 0, width: 2560, height: 1440),
            display: DisplayRect(x: 0, y: 0, width: 2560, height: 1440)
        ),
        Case(
            name: "a display stacked above: positive screen y, negative display y",
            screen: ScreenRect(x: 0, y: 1440, width: 1920, height: 1080),
            display: DisplayRect(x: 0, y: -1080, width: 1920, height: 1080)
        ),
        Case(
            name: "a display to the left keeps its negative x in both systems",
            screen: ScreenRect(x: -1920, y: 360, width: 200, height: 200),
            display: DisplayRect(x: -1920, y: 880, width: 200, height: 200)
        ),
        Case(
            name: "fractional origins survive the flip",
            screen: ScreenRect(x: 10.5, y: 20.25, width: 30.5, height: 40.75),
            display: DisplayRect(x: 10.5, y: 1379, width: 30.5, height: 40.75)
        )
    ]

    @Test("Screen rects flip to display rects", arguments: cases)
    func screenToDisplay(testCase: Case) {
        #expect(testCase.screen.inDisplaySpace(space) == testCase.display, "\(testCase.name)")
    }

    @Test("Display rects flip back to screen rects", arguments: cases)
    func displayToScreen(testCase: Case) {
        #expect(testCase.display.inScreenSpace(space) == testCase.screen, "\(testCase.name)")
    }

    @Test("The flip is its own inverse", arguments: cases)
    func roundTrip(testCase: Case) {
        #expect(testCase.screen.inDisplaySpace(space).inScreenSpace(space) == testCase.screen)
        #expect(testCase.display.inScreenSpace(space).inDisplaySpace(space) == testCase.display)
    }
}

@Suite("Points to pixels")
struct PixelConversionTests {
    struct Case: Sendable {
        let name: String
        let display: DisplayGeometry
        let local: DisplayRect
        let pixels: PixelRect
    }

    static let cases: [Case] = [
        Case(
            name: "Retina doubles every edge",
            display: builtIn,
            local: DisplayRect(x: 100, y: 200, width: 300, height: 400),
            pixels: PixelRect(x: 200, y: 400, width: 600, height: 800)
        ),
        Case(
            name: "a 1× display passes through untouched",
            display: above,
            local: DisplayRect(x: 100, y: 200, width: 300, height: 400),
            pixels: PixelRect(x: 100, y: 200, width: 300, height: 400)
        ),
        Case(
            name: "a half-point origin on Retina lands on a whole pixel",
            display: builtIn,
            local: DisplayRect(x: 10.5, y: 20.5, width: 100, height: 100),
            pixels: PixelRect(x: 21, y: 41, width: 200, height: 200)
        ),
        Case(
            name: "a half-point width keeps its extent instead of rounding twice",
            display: above,
            local: DisplayRect(x: 10.5, y: 10.5, width: 100.5, height: 100.5),
            pixels: PixelRect(x: 11, y: 11, width: 100, height: 100)
        ),
        Case(
            name: "the full built-in display is its backing store",
            display: builtIn,
            local: DisplayRect(x: 0, y: 0, width: 2560, height: 1440),
            pixels: PixelRect(x: 0, y: 0, width: 5120, height: 2880)
        )
    ]

    @Test("Local point rects convert to backing-store pixels", arguments: cases)
    func pointsToPixels(testCase: Case) {
        #expect(testCase.display.pixels(for: testCase.local) == testCase.pixels, "\(testCase.name)")
    }

    @Test("A display reports its own backing-store size")
    func displayPixelSize() {
        #expect(builtIn.pixelSize == PixelSize(width: 5120, height: 2880))
        #expect(above.pixelSize == PixelSize(width: 1920, height: 1080))
    }
}

@Suite("Rebasing onto a display")
struct DisplayLocalTests {
    @Test("A rect on the primary display is already local")
    func primaryIsIdentity() {
        let global = DisplayRect(x: 100, y: 100, width: 50, height: 50)
        #expect(builtIn.localRect(for: global) == global)
    }

    @Test("A rect on a display above is rebased off its negative origin")
    func rebasesNegativeOrigin() {
        let global = DisplayRect(x: 100, y: -1000, width: 50, height: 50)
        #expect(above.localRect(for: global) == DisplayRect(x: 100, y: 80, width: 50, height: 50))
    }

    @Test("A rect on a display to the left is rebased off its negative x")
    func rebasesNegativeX() {
        let global = DisplayRect(x: -1820, y: 40, width: 50, height: 50)
        #expect(left.localRect(for: global) == DisplayRect(x: 100, y: 40, width: 50, height: 50))
    }

    @Test("A local rect maps back to the global one it came from")
    func globalIsTheInverseOfLocal() {
        let global = DisplayRect(x: 100, y: -1000, width: 50, height: 50)
        let local = above.localRect(for: global)
        #expect(above.globalRect(for: local) == global)
    }

    @Test("Screen selection to pixel request, end to end")
    func fullPipeline() {
        // What the overlay hands us: an AppKit rect on the built-in Retina display.
        let selection = ScreenRect(x: 200, y: 300, width: 400, height: 200)
        let global = selection.inDisplaySpace(space)
        let local = builtIn.localRect(for: global)

        #expect(global == DisplayRect(x: 200, y: 940, width: 400, height: 200))
        #expect(local == global)
        #expect(builtIn.pixels(for: local) == PixelRect(x: 400, y: 1880, width: 800, height: 400))
    }
}

@Suite("Clamping to a display")
struct ClampingTests {
    @Test("A contained rect is returned unchanged")
    func containedIsUnchanged() {
        let rect = DisplayRect(x: 10, y: 10, width: 100, height: 100)
        #expect(builtIn.clamped(rect) == rect)
    }

    @Test("A rect running off the edge is trimmed, not moved")
    func overhangIsTrimmed() {
        let rect = DisplayRect(x: 2500, y: 1400, width: 200, height: 200)
        #expect(builtIn.clamped(rect) == DisplayRect(x: 2500, y: 1400, width: 60, height: 40))
    }

    @Test("A rect on another display does not clamp onto this one")
    func disjointIsNil() {
        #expect(builtIn.clamped(DisplayRect(x: 0, y: -1080, width: 100, height: 100)) == nil)
        #expect(above.clamped(DisplayRect(x: 0, y: 500, width: 100, height: 100)) == nil)
    }

    @Test("A rect touching only the edge has no area to capture")
    func edgeTouchIsNil() {
        #expect(builtIn.clamped(DisplayRect(x: 2560, y: 0, width: 100, height: 100)) == nil)
    }
}

@Suite("Screen rect to pixel point")
struct PixelPointTests {
    private let frame = ScreenRect(x: 100, y: 200, width: 400, height: 300)
    private let scale = DisplayScale(2)

    @Test("The top of the rect is the top of the frame")
    func topMapsNearOrigin() throws {
        let point = try #require(frame.pixelPoint(for: ScreenPoint(x: 100, y: 499), scale: scale))
        #expect(point.x == 0)
        #expect(abs(point.y - 2) < 0.001)
    }

    @Test("The bottom-left of the rect is the bottom of the frame")
    func bottomLeftIsBottom() throws {
        let point = try #require(frame.pixelPoint(for: ScreenPoint(x: 100, y: 200), scale: scale))
        #expect(point.x == 0)
        #expect(point.y == 600)
    }

    @Test("A click outside the rect is rejected")
    func outsideIsNil() {
        #expect(frame.pixelPoint(for: ScreenPoint(x: 50, y: 350), scale: scale) == nil)
        #expect(frame.contains(ScreenPoint(x: 50, y: 350)) == false)
    }

    @Test("A click inside is in backing pixels")
    func insideIsScaled() throws {
        let point = try #require(frame.pixelPoint(for: ScreenPoint(x: 200, y: 350), scale: scale))
        #expect(point.x == 200)
        #expect(point.y == 300)
    }
}

/// Seeding the overlay's pointer before the first mouse event (T-CAP-2): AppKit screen
/// space in, flipped view points out.
@Suite("ScreenRect top-left local point")
struct TopLeftLocalPointTests {
    /// A secondary display to the right of, and lower than, the main one.
    private let frame = ScreenRect(x: 1440, y: -200, width: 1920, height: 1080)

    @Test("Screen points map to top-left view points", arguments: [
        (ScreenPoint(x: 1440, y: 879), CGPoint(x: 0, y: 1)),
        (ScreenPoint(x: 1440, y: -200), CGPoint(x: 0, y: 1080)),
        (ScreenPoint(x: 2400, y: 340), CGPoint(x: 960, y: 540)),
        (ScreenPoint(x: 3359, y: 0), CGPoint(x: 1919, y: 880)),
    ])
    func maps(point: ScreenPoint, expected: CGPoint) {
        #expect(frame.topLeftLocalPoint(for: point) == expected)
    }

    @Test("A point on another display is nil", arguments: [
        ScreenPoint(x: 100, y: 100),
        ScreenPoint(x: 3360, y: 0),
        ScreenPoint(x: 2000, y: 880),
    ])
    func outside(point: ScreenPoint) {
        #expect(frame.topLeftLocalPoint(for: point) == nil)
    }
}
