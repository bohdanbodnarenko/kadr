import CoreGraphics
import CoreText
import Foundation
import Shared

/// The keystroke and speech caption pill (docs/09 U3.2, docs/13 T2.2).
enum CaptionCanvas {
    static func image(
        text: String,
        fontSize: CGFloat,
        opacity: Double,
        appearance: OverlayChromeAppearance = .dark,
        activeIndex: Int? = nil,
        spokenCount: Int = 0,
        maxWidth: CGFloat? = nil
    ) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = Self.attributed(
            text: text,
            font: font,
            opacity: opacity,
            appearance: appearance,
            activeIndex: activeIndex,
            spokenCount: spokenCount
        )
        let padding = fontSize * 0.6
        if let maxWidth, maxWidth > padding * 2 + fontSize {
            return wrappedImage(
                attributed: attributed,
                fontSize: fontSize,
                padding: padding,
                maxWidth: maxWidth,
                chrome: (opacity, appearance)
            )
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let width = Int((bounds.width + padding * 2).rounded(.up))
        let height = Int((bounds.height + padding * 1.2).rounded(.up))

        return BitmapCanvas.image(width: width, height: height) { context in
            fillPill(in: context, width: width, height: height, opacity: opacity, appearance: appearance)
            context.textPosition = CGPoint(x: padding - bounds.minX, y: padding * 0.6 - bounds.minY)
            CTLineDraw(line, context)
        }
    }

    private static func wrappedImage(
        attributed: NSAttributedString,
        fontSize: CGFloat,
        padding: CGFloat,
        maxWidth: CGFloat,
        chrome: (Double, OverlayChromeAppearance)
    ) -> CGImage? {
        let opacity = chrome.0
        let appearance = chrome.1
        let inner = maxWidth - padding * 2
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var fit = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: inner, height: fontSize * 4),
            &fit
        )
        let width = Int((min(suggested.width, inner) + padding * 2).rounded(.up))
        let height = Int((min(suggested.height, fontSize * 3.6) + padding * 1.2).rounded(.up))
        let path = CGPath(
            rect: CGRect(x: padding, y: padding * 0.4, width: inner, height: CGFloat(height) - padding),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        return BitmapCanvas.image(width: width, height: height) { context in
            fillPill(in: context, width: width, height: height, opacity: opacity, appearance: appearance)
            CTFrameDraw(frame, context)
        }
    }

    private static func fillPill(
        in context: CGContext,
        width: Int,
        height: Int,
        opacity: Double,
        appearance: OverlayChromeAppearance
    ) {
        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        switch appearance {
        case .dark:
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.65 * opacity)
        case .light:
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.86 * opacity)
        }
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: min(rect.height / 2, 14),
            cornerHeight: min(rect.height / 2, 14),
            transform: nil
        ))
        context.fillPath()
    }

    /// Warm gold on the live word, full white on what has been said, dim on what has not.
    static let activeRed: CGFloat = 1
    static let activeGreen: CGFloat = 0.82
    static let activeBlue: CGFloat = 0.28
    static let upcomingAlpha: CGFloat = 0.42

    static func attributed(
        text: String,
        font: CTFont,
        opacity: Double,
        appearance: OverlayChromeAppearance = .dark,
        activeIndex: Int?,
        spokenCount: Int
    ) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let karaoke = activeIndex != nil || spokenCount > 0
        guard karaoke, words.count > 1 || activeIndex != nil else {
            return NSAttributedString(string: text, attributes: [
                fontKey: font,
                colorKey: Self.ink(opacity, appearance: appearance)
            ])
        }
        let result = NSMutableAttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " ", attributes: [
                    fontKey: font,
                    colorKey: Self.ink(opacity, appearance: appearance)
                ]))
            }
            result.append(NSAttributedString(string: word, attributes: [
                fontKey: font,
                colorKey: Self.wordColor(
                    index: index,
                    activeIndex: activeIndex,
                    spokenCount: spokenCount,
                    opacity: opacity,
                    appearance: appearance
                )
            ]))
        }
        return result
    }

    private static func wordColor(
        index: Int,
        activeIndex: Int?,
        spokenCount: Int,
        opacity: Double,
        appearance: OverlayChromeAppearance
    ) -> CGColor {
        if index == activeIndex {
            return CGColor(
                red: activeRed,
                green: activeGreen,
                blue: activeBlue,
                alpha: opacity
            )
        }
        if index < spokenCount {
            return ink(opacity, appearance: appearance)
        }
        return CGColor(
            red: appearance == .light ? 0.15 : 1,
            green: appearance == .light ? 0.15 : 1,
            blue: appearance == .light ? 0.18 : 1,
            alpha: upcomingAlpha * opacity
        )
    }

    private static func ink(_ opacity: Double, appearance: OverlayChromeAppearance) -> CGColor {
        switch appearance {
        case .dark:
            CGColor(red: 1, green: 1, blue: 1, alpha: opacity)
        case .light:
            CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: opacity)
        }
    }
}
