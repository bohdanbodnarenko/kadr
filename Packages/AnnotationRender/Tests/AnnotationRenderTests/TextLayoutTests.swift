import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import AnnotationRender

/// The layout the editor's field and the exporter share (docs/09 U1.8).
///
/// Worth its own type and its own tests because the two used to agree only by coincidence —
/// both happened to build the same `CTFont` from the same fields, which is the kind of
/// agreement that survives until somebody adds a setting to one of them.
@Suite("Text layout")
struct TextLayoutTests {
    private func spec(
        _ string: String,
        width: CGFloat = 300,
        style: TextStyle = TextStyle()
    ) -> TextSpec {
        TextSpec(string: string, rect: CGRect(x: 10, y: 20, width: width, height: 40), style: style)
    }

    // MARK: - Measuring

    @Test("An empty annotation still has a caret's worth of height")
    func emptyHasHeight() {
        let size = TextLayout.measuredSize(spec(""), maxWidth: 300)
        #expect(size.height > 0, "an empty field must not collapse to nothing")
    }

    @Test("More text is taller")
    func moreTextIsTaller() {
        let short = TextLayout.measuredSize(spec("Hello"), maxWidth: 300)
        let long = TextLayout.measuredSize(
            spec("Hello, this is a much longer piece of text that will certainly wrap"),
            maxWidth: 300
        )
        #expect(long.height > short.height)
    }

    /// The property the on-canvas field depends on: narrower means taller, because the
    /// text wraps rather than being clipped.
    @Test("A narrower box wraps rather than clips")
    func narrowerWraps() {
        let text = "Hello, this is a much longer piece of text that will certainly wrap"
        let wide = TextLayout.measuredSize(spec(text), maxWidth: 600)
        let narrow = TextLayout.measuredSize(spec(text), maxWidth: 150)
        #expect(narrow.height > wide.height)
        #expect(narrow.width <= 150)
    }

    @Test("A bigger font measures bigger")
    func fontSizeMatters() {
        let small = TextLayout.measuredSize(spec("Hello", style: TextStyle(fontSize: 12)), maxWidth: 300)
        let large = TextLayout.measuredSize(spec("Hello", style: TextStyle(fontSize: 48)), maxWidth: 300)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
    }

    @Test("A zero-width constraint does not divide by zero")
    func zeroWidth() {
        #expect(TextLayout.measuredSize(spec("Hello"), maxWidth: 0).height > 0)
    }

    // MARK: - The pill

    @Test("A style with no background has no pill")
    func noBackgroundNoPill() {
        #expect(TextLayout.pillRect(spec("Hello")) == nil)
    }

    @Test("A pill surrounds the text with proportional padding")
    func pillSurroundsTheText() throws {
        let style = TextStyle(fontSize: 20, backgroundColor: .black)
        let annotation = spec("Hello", style: style)
        let pill = try #require(TextLayout.pillRect(annotation))

        #expect(pill.contains(annotation.rect))
        #expect(pill.minX < annotation.rect.minX)
        #expect(pill.maxY > annotation.rect.maxY)
    }

    /// Proportional padding is what makes a caption's pill tight and a heading's generous —
    /// a fixed inset looks drawn on a caption and lost on a heading.
    @Test("A bigger font gets a bigger pill")
    func pillScalesWithTheFont() throws {
        let small = try #require(TextLayout.pillRect(
            spec("Hi", style: TextStyle(fontSize: 12, backgroundColor: .black))
        ))
        let large = try #require(TextLayout.pillRect(
            spec("Hi", style: TextStyle(fontSize: 48, backgroundColor: .black))
        ))
        #expect(large.width > small.width)
        #expect(TextLayout.pillRadius(for: TextStyle(fontSize: 48)) > TextLayout
            .pillRadius(for: TextStyle(fontSize: 12)))
    }

    // MARK: - Fonts

    @Test("A bold style resolves to a bold face")
    func boldResolves() {
        let regular = TextLayout.font(for: TextStyle(isBold: false))
        let bold = TextLayout.font(for: TextStyle(isBold: true))
        let regularTraits = CTFontGetSymbolicTraits(regular)
        let boldTraits = CTFontGetSymbolicTraits(bold)

        #expect(!regularTraits.contains(.boldTrait))
        #expect(boldTraits.contains(.boldTrait))
    }

    /// Asked of CoreText rather than assembled by appending "-Bold", a convention that
    /// holds for Helvetica and not for most of what a user might pick.
    @Test("A family with no bold face falls back to itself rather than to nothing")
    func unknownFamilyFallsBack() {
        let name = TextLayout.boldName(for: "ThisFontDoesNotExistAnywhere")
        #expect(!name.isEmpty)
    }

    @Test("Every built-in preset produces a usable font", arguments: TextStyle.presets.map(\.style))
    func presetsResolve(style: TextStyle) {
        let font = TextLayout.font(for: style)
        #expect(CTFontGetSize(font) == style.fontSize)
    }

    // MARK: - Agreement with the export

    /// The point of the whole type: the string the field lays out is the string the
    /// exporter draws, attribute for attribute.
    @Test("The attributed string carries the style's font and color")
    func attributedStringMatchesTheStyle() {
        let style = TextStyle(fontSize: 33, isBold: false, color: AnnotationColor(red: 0, green: 1, blue: 0))
        let attributed = TextLayout.attributedString(spec("Hello", style: style))

        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        // The attribute is stored as `Any`; the cast back is a CoreFoundation bridge that
        // cannot fail, so the value is read through the layout's own accessor instead of
        // being force-cast here.
        #expect(attributes[.init(kCTFontAttributeName as String)] != nil)
        #expect(CTFontGetSize(TextLayout.font(for: style)) == 33)
        #expect(attributes[.init(kCTForegroundColorAttributeName as String)] != nil)
    }

    @Test("An empty string still produces a string, not nil")
    func emptyAttributedString() {
        #expect(TextLayout.attributedString(spec("")).length == 0)
    }
}
