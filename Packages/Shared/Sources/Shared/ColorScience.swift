import Foundation

/// An sRGB colour with components in 0…1 (docs/03 §3 P3, docs/06 M22).
///
/// Its own type rather than `CGColor` because everything here is arithmetic that has to
/// be exactly right and exactly testable: a colour picker that reports the wrong hex, or a
/// contrast figure that is off by a step, is worse than not having one — someone will ship
/// the result.
public struct SampledColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 8-bit components, which is what a screenshot's pixels are.
    public init(red8: UInt8, green8: UInt8, blue8: UInt8) {
        self.init(
            red: Double(red8) / 255,
            green: Double(green8) / 255,
            blue: Double(blue8) / 255
        )
    }

    public var red8: UInt8 {
        Self.byte(red)
    }

    public var green8: UInt8 {
        Self.byte(green)
    }

    public var blue8: UInt8 {
        Self.byte(blue)
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    public static let white = SampledColor(red: 1, green: 1, blue: 1)
    public static let black = SampledColor(red: 0, green: 0, blue: 0)
}

/// Hue, saturation, lightness — the components, not a tuple, so the fields have names.
public struct HSLComponents: Hashable, Sendable {
    /// Degrees, 0…360.
    public var hue: Double
    /// 0…1.
    public var saturation: Double
    /// 0…1.
    public var lightness: Double

    public init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }
}

/// OKLCH: perceptual lightness, chroma and hue (docs/03 §3 P3).
///
/// Worth having over HSL because equal steps in OKLCH look like equal steps, which is what
/// a designer picking a palette out of a screenshot actually needs.
public struct OKLCHComponents: Hashable, Sendable {
    /// 0…1, perceptual lightness.
    public var lightness: Double
    /// 0…~0.4 in practice.
    public var chroma: Double
    /// Degrees, 0…360.
    public var hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }
}

/// How a picked colour is written out (docs/06 M22).
public enum ColorFormat: String, CaseIterable, Sendable, Hashable, Codable {
    case hex
    case rgb
    case hsl
    case oklch

    public var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        }
    }

    /// The next format, for a key that cycles them.
    public var next: ColorFormat {
        let all = ColorFormat.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// Colour conversions and contrast maths (docs/06 M22).
///
/// The conversions follow the published definitions rather than an approximation: sRGB's
/// piecewise transfer function, Björn Ottosson's OKLab matrices, WCAG 2's relative
/// luminance, and APCA-W3 0.1.9. Pika (MIT) was consulted for the shape of the API.
public enum ColorScience {
    // MARK: - sRGB ↔ linear

    /// sRGB's piecewise transfer function. Not a plain 2.2 power: the linear toe near
    /// black is where the difference actually shows, and it is the part a naive
    /// implementation drops.
    public static func linear(_ channel: Double) -> Double {
        let value = max(0, min(1, channel))
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    public static func encoded(_ linear: Double) -> Double {
        let value = max(0, min(1, linear))
        return value <= 0.0031308
            ? value * 12.92
            : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    // MARK: - HSL

    public static func hsl(_ color: SampledColor) -> HSLComponents {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let chroma = maximum - minimum
        let lightness = (maximum + minimum) / 2

        guard chroma > 0 else {
            return HSLComponents(hue: 0, saturation: 0, lightness: lightness)
        }

        let saturation = chroma / (1 - abs(2 * lightness - 1))
        var hue: Double = switch maximum {
        case color.red:
            ((color.green - color.blue) / chroma).truncatingRemainder(dividingBy: 6)
        case color.green:
            (color.blue - color.red) / chroma + 2
        default:
            (color.red - color.green) / chroma + 4
        }
        hue *= 60
        if hue < 0 {
            hue += 360
        }
        return HSLComponents(hue: hue, saturation: saturation, lightness: lightness)
    }

    // MARK: - OKLab / OKLCH

    /// Ottosson's OKLab, from linear sRGB.
    public static func oklch(_ color: SampledColor) -> OKLCHComponents {
        let red = linear(color.red)
        let green = linear(color.green)
        let blue = linear(color.blue)

        let long = 0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue
        let medium = 0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue
        let short = 0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue

        let lRoot = cbrt(long)
        let mRoot = cbrt(medium)
        let sRoot = cbrt(short)

        let lightness = 0.210_454_255_3 * lRoot + 0.793_617_785 * mRoot - 0.004_072_046_8 * sRoot
        let aAxis = 1.977_998_495_1 * lRoot - 2.428_592_205 * mRoot + 0.450_593_709_9 * sRoot
        let bAxis = 0.025_904_037_1 * lRoot + 0.782_771_766_2 * mRoot - 0.808_675_766 * sRoot

        var hue = atan2(bAxis, aAxis) * 180 / .pi
        if hue < 0 {
            hue += 360
        }
        return OKLCHComponents(
            lightness: lightness,
            chroma: hypot(aAxis, bAxis),
            hue: hue
        )
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance.
    public static func relativeLuminance(_ color: SampledColor) -> Double {
        0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    /// WCAG 2.1 contrast ratio, 1…21.
    ///
    /// Kept alongside APCA rather than replaced by it because WCAG is what accessibility
    /// requirements are still written against, and a designer checking a screenshot needs
    /// the number their acceptance criteria name.
    public static func wcagContrast(_ first: SampledColor, _ second: SampledColor) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// APCA-W3 (0.1.9) lightness contrast, `Lc`.
    ///
    /// Signed and asymmetric on purpose: unlike WCAG, APCA distinguishes dark text on a
    /// light background (positive) from light text on a dark one (negative), which is the
    /// whole reason it predicts readability better. Roughly, |Lc| 45 is large text, 60 is
    /// body text, 75 is comfortable body text.
    public static func apcaLc(text: SampledColor, background: SampledColor) -> Double {
        let textY = apcaLuminance(text)
        let backgroundY = apcaLuminance(background)

        // Very dark colours are lifted so the curve behaves near black.
        let textClamped = clampY(textY)
        let backgroundClamped = clampY(backgroundY)

        // Below this the two are the same colour as far as readability goes.
        guard abs(backgroundClamped - textClamped) >= 0.0005 else { return 0 }

        let contrast: Double
        if backgroundClamped > textClamped {
            // Dark text on a light background.
            let raw = (pow(backgroundClamped, 0.56) - pow(textClamped, 0.57)) * 1.14
            contrast = raw < 0.1 ? 0 : raw - 0.027
        } else {
            // Light text on a dark background.
            let raw = (pow(backgroundClamped, 0.65) - pow(textClamped, 0.62)) * 1.14
            contrast = raw > -0.1 ? 0 : raw + 0.027
        }
        return contrast * 100
    }

    /// APCA's own luminance: a plain power curve, not sRGB's piecewise one.
    private static func apcaLuminance(_ color: SampledColor) -> Double {
        0.2126729 * pow(max(0, min(1, color.red)), 2.4)
            + 0.7151522 * pow(max(0, min(1, color.green)), 2.4)
            + 0.0721750 * pow(max(0, min(1, color.blue)), 2.4)
    }

    private static func clampY(_ value: Double) -> Double {
        // APCA's black soft-clamp: below the threshold, lift towards it.
        value > 0.022 ? value : value + pow(0.022 - value, 1.414)
    }
}

public extension SampledColor {
    var hsl: HSLComponents {
        ColorScience.hsl(self)
    }

    var oklch: OKLCHComponents {
        ColorScience.oklch(self)
    }

    /// The colour as text, in the format the user picked.
    ///
    /// The exact spellings are the ones that paste straight into CSS, because that is
    /// where a colour picked out of a screenshot is going.
    func formatted(_ format: ColorFormat) -> String {
        switch format {
        case .hex:
            String(format: "#%02X%02X%02X", red8, green8, blue8)
        case .rgb:
            "rgb(\(red8) \(green8) \(blue8))"
        case .hsl:
            {
                let components = hsl
                return "hsl(\(Self.round(components.hue))"
                    + " \(Self.round(components.saturation * 100))%"
                    + " \(Self.round(components.lightness * 100))%)"
            }()
        case .oklch:
            {
                let components = oklch
                return "oklch(\(Self.percent(components.lightness))"
                    + " \(Self.decimal(components.chroma))"
                    + " \(Self.round(components.hue)))"
            }()
        }
    }

    private static func round(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// A colour picked off a capture, and optionally one to compare it with (docs/06 M22).
public struct ColorPick: Hashable, Sendable {
    public var color: SampledColor
    /// The second sample, when the user asked to compare. `nil` means no contrast readout.
    public var comparison: SampledColor?
    public var format: ColorFormat

    public init(color: SampledColor, comparison: SampledColor? = nil, format: ColorFormat = .hex) {
        self.color = color
        self.comparison = comparison
        self.format = format
    }

    public var text: String {
        color.formatted(format)
    }

    /// WCAG contrast against the comparison colour, if there is one.
    public var wcagContrast: Double? {
        comparison.map { ColorScience.wcagContrast(color, $0) }
    }

    /// APCA `Lc` treating the picked colour as text on the comparison background.
    public var apcaLc: Double? {
        comparison.map { ColorScience.apcaLc(text: color, background: $0) }
    }

    /// The one-line contrast readout, or nil until a second colour is sampled.
    ///
    /// Both numbers, because they answer different questions: the WCAG ratio is what an
    /// acceptance criterion is written against, and the APCA figure is the one that
    /// actually predicts whether the text is readable.
    public var contrastText: String? {
        guard let wcagContrast, let apcaLc else { return nil }
        return String(format: "%.2f:1 · Lc %.0f", wcagContrast, apcaLc)
    }

    /// What the clipboard gets: the colour, and the contrast when one was measured.
    public var clipboardText: String {
        guard let contrastText else { return text }
        return "\(text)  \(contrastText)"
    }
}
