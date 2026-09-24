import CoreGraphics
import OverlayKit
import Shared
import Testing
@testable import SelectionUI

/// The keyboard goes to the display under the pointer, not the last panel made (T-CAP-2).
@MainActor
@Suite("Key display")
struct KeyDisplayTests {
    /// A laptop at the origin and an external display to its left, lower down.
    private let displays = [
        ScreenDescriptor(displayID: 1, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982), backingScaleFactor: 2),
        ScreenDescriptor(displayID: 2, frame: ScreenRect(x: -2560, y: -400, width: 2560, height: 1440), backingScaleFactor: 1),
    ]

    @Test("The display containing the pointer is chosen", arguments: [
        (ScreenPoint(x: 10, y: 10), UInt32?(1)),
        (ScreenPoint(x: 1511, y: 981), UInt32?(1)),
        (ScreenPoint(x: -1, y: 0), UInt32?(2)),
        (ScreenPoint(x: -2560, y: -400), UInt32?(2)),
        (ScreenPoint(x: 1512, y: 0), UInt32?.none),
        (ScreenPoint(x: -100, y: 1100), UInt32?.none),
    ] as [(ScreenPoint, UInt32?)])
    func underPointer(pointer: ScreenPoint, expected: CGDirectDisplayID?) {
        #expect(SelectionOverlayController.display(under: pointer, in: displays)?.displayID == expected)
    }
}
