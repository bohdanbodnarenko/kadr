import CoreGraphics
import Foundation
import Testing
@testable import Kadr

/// docs/17 T-OUT-13: a pin remembered on a display that has gone comes back on-screen.
@Suite("Pin restore clamping")
struct PinRestoreClampTests {
    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let frame: CGRect
        let expected: CGRect

        var testDescription: String {
            name
        }
    }

    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    static let rows: [Row] = [
        Row(
            name: "on screen stays put",
            frame: CGRect(x: 100, y: 100, width: 300, height: 200),
            expected: CGRect(x: 100, y: 100, width: 300, height: 200)
        ),
        Row(
            name: "mostly off the right edge but reachable stays put",
            frame: CGRect(x: 1400, y: 100, width: 300, height: 200),
            expected: CGRect(x: 1400, y: 100, width: 300, height: 200)
        ),
        Row(
            name: "on an unplugged display to the right moves in",
            frame: CGRect(x: 2000, y: 300, width: 300, height: 200),
            expected: CGRect(x: 1140, y: 300, width: 300, height: 200)
        ),
        Row(
            name: "below the screen moves up",
            frame: CGRect(x: 100, y: -900, width: 300, height: 200),
            expected: CGRect(x: 100, y: 0, width: 300, height: 200)
        ),
        Row(
            name: "larger than the screen shrinks to it",
            frame: CGRect(x: 3000, y: 0, width: 2000, height: 1000),
            expected: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
    ]

    @Test("Restored frames are clamped to a connected screen", arguments: rows)
    func clamps(row: Row) {
        let record = PinRecord(path: "/tmp/pin.png", frame: row.frame, alpha: 1, clickThrough: false)
        #expect(record.clamped(to: [Self.screen]).frame == row.expected)
    }

    @Test("With no screens reported the record is left alone")
    func noScreens() {
        let record = PinRecord(
            path: "/tmp/pin.png",
            frame: CGRect(x: 5000, y: 0, width: 10, height: 10),
            alpha: 1,
            clickThrough: false
        )
        #expect(record.clamped(to: []) == record)
    }
}
