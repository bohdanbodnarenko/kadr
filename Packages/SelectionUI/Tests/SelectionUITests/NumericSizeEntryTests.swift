import CoreGraphics
import Shared
import Testing
@testable import SelectionUI

private func entry(typing keys: String) -> NumericSizeEntry {
    var entry = NumericSizeEntry()
    for character in keys {
        entry.accept(character)
    }
    return entry
}

@Suite("Typing an exact size")
struct NumericSizeEntryTests {
    @Test("Digits then a separator then digits give a size", arguments: [
        ("640x480", CGSize(width: 640, height: 480)),
        ("640X480", CGSize(width: 640, height: 480)),
        ("640×480", CGSize(width: 640, height: 480)),
        ("640,480", CGSize(width: 640, height: 480)),
        ("640 480", CGSize(width: 640, height: 480)),
        ("1920x1080", CGSize(width: 1920, height: 1080))
    ])
    func parsesSizes(keys: String, expected: CGSize) {
        #expect(entry(typing: keys).size == expected)
    }

    @Test("A width on its own means a square")
    func widthOnlyIsSquare() {
        #expect(entry(typing: "400").size == CGSize(width: 400, height: 400))
    }

    @Test("Nothing typed is not a size")
    func emptyIsNil() {
        #expect(NumericSizeEntry().size == nil)
        #expect(NumericSizeEntry().isEmpty)
    }

    @Test("A separator before any digit is ignored rather than stranding entry")
    func leadingSeparatorIgnored() {
        var value = NumericSizeEntry()
        #expect(value.accept("x") == false)
        #expect(value.field == .width)
    }

    @Test("Letters are refused so the caller can handle them as shortcuts")
    func lettersAreRefused() {
        var value = NumericSizeEntry()
        #expect(value.accept("q") == false)
        #expect(value.isEmpty)
    }

    @Test("A field stops accepting digits at five, so a stuck key cannot run away")
    func digitLimit() {
        let value = entry(typing: "1234567")
        #expect(value.widthText == "12345")
    }

    @Test("Backspace deletes within a field then steps back to the previous one")
    func backspace() {
        var value = entry(typing: "640x48")
        value.deleteBackward()
        #expect(value.heightText == "4")

        value.deleteBackward()
        #expect(value.heightText.isEmpty)
        #expect(value.field == .height)

        value.deleteBackward()
        #expect(value.field == .width)
        #expect(value.widthText == "64")
    }

    @Test("Backspace on an empty entry is refused")
    func backspaceOnEmpty() {
        var value = NumericSizeEntry()
        #expect(value.deleteBackward() == false)
    }

    @Test("Zero is not a size")
    func zeroIsNotASize() {
        #expect(entry(typing: "0").size == nil)
        #expect(entry(typing: "640x0").size == nil)
    }

    @Test("Reset clears everything")
    func reset() {
        var value = entry(typing: "640x480")
        value.reset()
        #expect(value.isEmpty)
        #expect(value.field == .width)
    }

    @Test("The overlay shows what has been typed so far", arguments: [
        ("", "– × …"),
        ("6", "6 × …"),
        ("640", "640 × …"),
        ("640x", "640 × …"),
        ("640x4", "640 × 4")
    ])
    func displayText(keys: String, expected: String) {
        #expect(entry(typing: keys).displayText == expected)
    }
}

@Suite("Dimension badge")
struct DimensionFormatterTests {
    @Test("On a 1× display the badge is just points")
    func nonRetina() {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        #expect(DimensionFormatter.text(for: rect, scale: .oneToOne) == "640 × 480")
    }

    @Test("On Retina the badge shows the pixel size too, because that is what gets saved")
    func retina() {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        #expect(DimensionFormatter.text(for: rect, scale: .retina) == "640 × 480 pt · 1280 × 960 px")
    }

    @Test("The badge's pixel size agrees with what the capture engine will produce")
    func agreesWithCaptureGeometry() {
        // A sub-point origin is where a naive width × scale disagrees with edge rounding.
        let rect = CGRect(x: 10.5, y: 10.5, width: 100.5, height: 100.5)
        let display = DisplayGeometry(
            displayID: 1,
            frame: DisplayRect(x: 0, y: 0, width: 1000, height: 800),
            scale: .oneToOne
        )
        let fromEngine = display.pixels(for: DisplayRect(cgRect: rect))
        let fromBadge = DimensionFormatter.pixelSize(of: rect, scale: .oneToOne)

        #expect(fromBadge == fromEngine.size)
    }

    @Test("The loupe readout shows whole point coordinates")
    func pointerText() {
        #expect(DimensionFormatter.pointerText(at: CGPoint(x: 100.4, y: 200.6)) == "100, 201")
    }

    @Test("Colours read out as hex")
    func hexText() {
        #expect(DimensionFormatter.hexText(red: 255, green: 128, blue: 0) == "#FF8000")
        #expect(DimensionFormatter.hexText(red: 0, green: 0, blue: 0) == "#000000")
    }
}
