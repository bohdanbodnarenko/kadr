import AnnotationModel
import CoreGraphics
import CoreText
import Foundation

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
    public static func font(for style: TextStyle) -> CTFont {
        let name = style.isBold ? boldName(for: style.fontName) : style.fontName
        return CTFontCreateWithName(name as CFString, style.fontSize, nil)
    }

    /// The attributed string a text annotation renders as.
    ///
    /// CoreText attribute names rather than AppKit's, for the same reason as above.
    public static func attributedString(_ spec: TextSpec) -> NSAttributedString {
        NSAttributedString(string: spec.string, attributes: [
            .init(kCTFontAttributeName as String): font(for: spec.style),
            .init(kCTForegroundColorAttributeName as String): spec.style.color.cgColor,
            .init(kCTParagraphStyleAttributeName as String): paragraphStyle(for: spec.style)
        ])
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
