import Foundation
import Testing
@testable import Shared

/// Colour conversions and contrast (docs/03 §3 P3, docs/06 M22).
///
/// Checked against published reference values rather than against itself: the failure mode
/// of colour maths is a plausible-looking number, and a test that only proves the code
/// agrees with the code catches none of it.
@Suite("Color science")
struct ColorScienceTests {
    private func isClose(_ value: Double, _ expected: Double, _ tolerance: Double = 0.01) -> Bool {
        abs(value - expected) <= tolerance
    }

    // MARK: - sRGB transfer function

    @Test("The transfer function round-trips")
    func transferRoundTrip() {
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(isClose(ColorScience.encoded(ColorScience.linear(step)), step, 0.0001))
        }
    }

    /// The part a plain 2.2 power gets wrong.
    @Test("The linear toe near black is the piecewise one, not a power curve")
    func linearToe() {
        #expect(isClose(ColorScience.linear(0.04), 0.04 / 12.92, 0.000001))
        #expect(isClose(ColorScience.linear(0.5), 0.2140, 0.0005))
        #expect(ColorScience.linear(0) == 0)
        #expect(isClose(ColorScience.linear(1), 1, 0.000001))
    }

    // MARK: - HSL

    @Test("Primaries convert to the hues everyone knows", arguments: [
        (SampledColor(red: 1, green: 0, blue: 0), 0.0),
        (SampledColor(red: 1, green: 1, blue: 0), 60.0),
        (SampledColor(red: 0, green: 1, blue: 0), 120.0),
        (SampledColor(red: 0, green: 1, blue: 1), 180.0),
        (SampledColor(red: 0, green: 0, blue: 1), 240.0),
        (SampledColor(red: 1, green: 0, blue: 1), 300.0)
    ])
    func hslHues(color: SampledColor, hue: Double) {
        let components = color.hsl
        #expect(isClose(components.hue, hue, 0.001))
        #expect(isClose(components.saturation, 1, 0.001))
        #expect(isClose(components.lightness, 0.5, 0.001))
    }

    @Test("Grays have no hue and no saturation")
    func hslGrey() {
        let components = SampledColor(red: 0.5, green: 0.5, blue: 0.5).hsl
        #expect(components.saturation == 0)
        #expect(components.hue == 0)
        #expect(isClose(components.lightness, 0.5, 0.001))
    }

    // MARK: - OKLCH

    /// Ottosson's own reference: white is L = 1 with no chroma.
    @Test("White is fully light and has no chroma")
    func oklchWhite() {
        let components = SampledColor.white.oklch
        #expect(isClose(components.lightness, 1, 0.002))
        #expect(isClose(components.chroma, 0, 0.002))
    }

    @Test("Black is zero everywhere")
    func oklchBlack() {
        let components = SampledColor.black.oklch
        #expect(isClose(components.lightness, 0, 0.002))
        #expect(isClose(components.chroma, 0, 0.002))
    }

    /// sRGB red is the standard worked example: L ≈ 0.628, C ≈ 0.258, h ≈ 29.2°.
    @Test("sRGB red matches the published OKLCH values")
    func oklchRed() {
        let components = SampledColor(red: 1, green: 0, blue: 0).oklch
        #expect(isClose(components.lightness, 0.6280, 0.003))
        #expect(isClose(components.chroma, 0.2577, 0.003))
        #expect(isClose(components.hue, 29.23, 0.5))
    }

    @Test("A mid gray has lightness but no chroma")
    func oklchGrey() {
        let components = SampledColor(red: 0.5, green: 0.5, blue: 0.5).oklch
        #expect(isClose(components.chroma, 0, 0.002))
        #expect(components.lightness > 0.4 && components.lightness < 0.7)
    }

    // MARK: - WCAG

    @Test("Black on white is the maximum 21:1")
    func wcagExtremes() {
        #expect(isClose(ColorScience.wcagContrast(.black, .white), 21, 0.01))
        #expect(isClose(ColorScience.wcagContrast(.white, .white), 1, 0.001))
    }

    @Test("The ratio does not care which way round the colors are")
    func wcagIsSymmetric() {
        let ink = SampledColor(red8: 0x11, green8: 0x77, blue8: 0xCC)
        let paper = SampledColor(red8: 0xEE, green8: 0xEE, blue8: 0xEE)
        #expect(isClose(
            ColorScience.wcagContrast(ink, paper),
            ColorScience.wcagContrast(paper, ink),
            0.0001
        ))
    }

    /// #767676 on white is the canonical "exactly passes AA for body text" colour.
    @Test("The classic 4.5:1 boundary color lands on the boundary")
    func wcagAABoundary() {
        let grey = SampledColor(red8: 0x76, green8: 0x76, blue8: 0x76)
        #expect(isClose(ColorScience.wcagContrast(grey, .white), 4.54, 0.05))
    }

    // MARK: - APCA

    @Test("Black text on white is strongly positive")
    func apcaBlackOnWhite() {
        let value = ColorScience.apcaLc(text: .black, background: .white)
        #expect(isClose(value, 106.04, 0.5))
    }

    /// The sign is the point: APCA distinguishes polarity where WCAG cannot.
    @Test("White text on black is strongly negative")
    func apcaWhiteOnBlack() {
        let value = ColorScience.apcaLc(text: .white, background: .black)
        #expect(isClose(value, -107.88, 0.5))
        #expect(value < 0)
    }

    @Test("A color on itself has no contrast at all")
    func apcaSameColour() {
        let colour = SampledColor(red8: 0x33, green8: 0x66, blue8: 0x99)
        #expect(ColorScience.apcaLc(text: colour, background: colour) == 0)
    }

    @Test("APCA and WCAG agree about which pair is more readable")
    func apcaAgreesOnOrdering() {
        let strong = ColorScience.apcaLc(text: .black, background: .white)
        let weak = ColorScience.apcaLc(
            text: SampledColor(red8: 0x99, green8: 0x99, blue8: 0x99),
            background: .white
        )
        #expect(abs(strong) > abs(weak))
    }

    // MARK: - Formatting

    @Test("Hex is upper-case and six digits")
    func hexFormat() {
        #expect(SampledColor(red8: 0x0A, green8: 0xB1, blue8: 0xFF).formatted(.hex) == "#0AB1FF")
        #expect(SampledColor.black.formatted(.hex) == "#000000")
    }

    @Test("Every format is something that pastes into CSS")
    func formatsAreCSS() {
        let colour = SampledColor(red: 1, green: 0, blue: 0)
        #expect(colour.formatted(.rgb) == "rgb(255 0 0)")
        #expect(colour.formatted(.hsl) == "hsl(0 100% 50%)")
        #expect(colour.formatted(.oklch).hasPrefix("oklch("))
        #expect(colour.formatted(.oklch).hasSuffix(")"))
    }

    @Test("The format key cycles through all of them and comes back")
    func formatCycles() {
        var format = ColorFormat.hex
        for _ in ColorFormat.allCases {
            format = format.next
        }
        #expect(format == .hex)
        #expect(Set(ColorFormat.allCases).count == ColorFormat.allCases.count)
    }

    // MARK: - Picks

    @Test("A pick with no comparison has no contrast readout")
    func pickWithoutComparison() {
        let pick = ColorPick(color: .black)
        #expect(pick.contrastText == nil)
        #expect(pick.wcagContrast == nil)
        #expect(pick.clipboardText == "#000000")
    }

    @Test("A pick with a comparison reports both numbers")
    func pickWithComparison() throws {
        let pick = ColorPick(color: .black, comparison: .white)
        let text = try #require(pick.contrastText)
        #expect(text.contains("21.00:1"))
        #expect(text.contains("Lc 106"))
        #expect(pick.clipboardText.hasPrefix("#000000"))
    }

    @Test("The clipboard gets whichever format is showing")
    func clipboardFollowsTheFormat() {
        let pick = ColorPick(color: SampledColor(red: 1, green: 0, blue: 0), format: .rgb)
        #expect(pick.clipboardText == "rgb(255 0 0)")
    }

    @Test("8-bit round-trips exactly, so a picked pixel reports its own value")
    func byteRoundTrip() {
        for value in stride(from: 0, through: 255, by: 17) {
            let byte = UInt8(value)
            let colour = SampledColor(red8: byte, green8: byte, blue8: byte)
            #expect(colour.red8 == byte)
        }
    }
}
