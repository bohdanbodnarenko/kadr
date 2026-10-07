import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import os

/// How a text annotation is laid out, for everyone who needs to know (docs/09 U1.8).
///
/// One place, because the editor's on-canvas field and the exporter have to agree
/// character for character. They currently agree by both happening to build the same
/// `CTFont` from the same fields — which is the kind of agreement that survives until
/// somebody adds a line-height setting to one of them.
///
/// CoreText rather than AppKit, so this stays out of a UI framework and could run in the
/// helper: the export path already does (docs/04 §2).
public enum TextLayout {
    /// Padding around the text inside its pill, as a fraction of the font size.
    ///
    /// Proportional so a caption's pill is tight and a heading's is generous, which is what
    /// makes a pill look drawn rather than computed.
    public static let pillPaddingRatio = CGSize(width: 0.25, height: 0.16)
    /// The pill's corner radius, likewise proportional.
    public static let pillRadiusRatio: CGFloat = 0.25

    /// The font a style resolves to.
    ///
    /// Cached, and resolved under one lock. A bold or italic variant is a round trip to
    /// the system font service, made for every text annotation on every render; and many
    /// threads asking for variants at once could leave every one of them waiting on that
    /// service indefinitely, which is what hung the AnnotationRender tests.
    public static func font(for style: TextStyle) -> CTFont {
        font(named: style.fontName, size: style.fontSize, bold: style.isBold, italic: style.isItalic)
    }

    /// A font by name, through the same cache, for the counter, measure and watermark
    /// labels, which build fonts on render threads too.
    public static func font(named name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        let key = FontKey(name: name, size: size, bold: bold, italic: italic)
        return fontCache.withLock { cache in
            if let font = cache[key] {
                return font
            }
            let font = FontBox(value: resolveFont(for: key))
            if cache.count >= maximumCachedFonts {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = font
            return font
        }.value
    }

    private struct FontKey: Hashable {
        let name: String
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    /// `CTFont` is immutable and documented as safe to use from any thread.
    private struct FontBox: @unchecked Sendable {
        let value: CTFont
    }

    /// A handful of styles per document; the cap only stops a size slider from growing it.
    private static let maximumCachedFonts = 64
    private static let fontCache = OSAllocatedUnfairLock(initialState: [FontKey: FontBox]())

    private static func resolveFont(for key: FontKey) -> CTFont {
        let base = CTFontCreateWithName(key.name as CFString, key.size, nil)
        var traits: CTFontSymbolicTraits = []
        if key.bold {
            traits.insert(.boldTrait)
        }
        if key.italic {
            traits.insert(.italicTrait)
        }
        guard !traits.isEmpty,
              let styled = CTFontCreateCopyWithSymbolicTraits(base, key.size, nil, traits, traits)
        else {
            return base
        }
        return styled
    }

    /// The attributed string a text annotation renders as.
    ///
    /// CoreText attribute names rather than AppKit's, for the same reason as above.
    public static func attributedString(_ spec: TextSpec) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font(for: spec.style),
            .init(kCTForegroundColorAttributeName as String): spec.style.color.cgColor,
            .init(kCTParagraphStyleAttributeName as String): paragraphStyle(for: spec.style)
        ]
        if spec.style.isUnderline {
            attributes[.init(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: spec.string, attributes: attributes)
    }

    /// The paragraph style a text annotation's alignment resolves to.
    ///
    /// `CTParagraphStyleCreate` rather than `NSMutableParagraphStyle`, so this file keeps
    /// its promise of running without a UI framework.
    public static func paragraphStyle(for style: TextStyle) -> CTParagraphStyle {
        var alignment = ctAlignment(for: style.alignment)
        return withUnsafeBytes(of: &alignment) { buffer in
            guard let address = buffer.baseAddress else {
                return CTParagraphStyleCreate(nil, 0)
            }
            let setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: buffer.count,
                value: address
            )
            return CTParagraphStyleCreate([setting], 1)
        }
    }

    static func ctAlignment(for alignment: TextStyle.Alignment) -> CTTextAlignment {
        switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    /// The size the text needs when wrapped to `maxWidth`.
    ///
    /// What makes the on-canvas field able to grow exactly as the export will: the field
    /// asks this, not its own text container.
    public static func measuredSize(_ spec: TextSpec, maxWidth: CGFloat) -> CGSize {
        guard !spec.string.isEmpty else {
            // An empty annotation still needs a caret's worth of height, or the field
            // collapses to nothing the moment the user clears it.
            return CGSize(width: 0, height: ceil(spec.style.fontSize * 1.2))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(spec))
        let constraint = CGSize(width: max(maxWidth, 1), height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            nil
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The padding around the text inside its pill.
    public static func pillPadding(for style: TextStyle) -> CGSize {
        CGSize(
            width: style.fontSize * pillPaddingRatio.width,
            height: style.fontSize * pillPaddingRatio.height
        )
    }

    /// The filled pill behind the text, or nil when the style has no background.
    public static func pillRect(_ spec: TextSpec) -> CGRect? {
        guard spec.style.backgroundColor != nil else { return nil }
        let padding = pillPadding(for: spec.style)
        return spec.rect.insetBy(dx: -padding.width, dy: -padding.height)
    }

    public static func pillRadius(for style: TextStyle) -> CGFloat {
        style.fontSize * pillRadiusRatio
    }

    /// The bold face of a family, or the family itself when it has none.
    ///
    /// Asked of CoreText rather than assembled by appending "-Bold": that convention holds
    /// for Helvetica and not for most of what a user might pick.
    public static func boldName(for family: String) -> String {
        let base = CTFontCreateWithName(family as CFString, 12, nil)
        guard let bold = CTFontCreateCopyWithSymbolicTraits(base, 12, nil, .boldTrait, .boldTrait) else {
            return family
        }
        return CTFontCopyPostScriptName(bold) as String
    }
}
