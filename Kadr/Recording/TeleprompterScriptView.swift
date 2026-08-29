import AppKit
import CoreText
import Shared
import StudioCore

/// How the prompter looks, which is entirely about being readable at a glance.
struct TeleprompterAppearance: Equatable {
    var fontSize: CGFloat = 30
    /// Reading a script off a beam-splitter glass means reading it backwards.
    var isMirrored = false
    /// How much of the panel the read-so-far text fades to.
    var pastOpacity: Double = 0.35

    static let smallestFont: CGFloat = 16
    static let largestFont: CGFloat = 72
}

/// Draws the script and keeps the reader's line in the middle (docs/08, teleprompter).
///
/// CoreText into a view rather than SwiftUI, for the same reason the selection overlay is
/// CALayer-only: this redraws on every frame of a scroll while a recording is running, and
/// the recording is the thing that must not stutter. A prompter that drops frames is also a
/// prompter somebody stumbles over, because the eye tracks a moving line.
///
/// The current line sits at the vertical centre and the text moves under it, rather than a
/// cursor moving down a static page. A reader's eyes then stay in one place, which is the
/// whole ergonomic point — and it is why the panel can be short.
@MainActor
final class TeleprompterScriptView: NSView {
    var script = TeleprompterScript(text: "") {
        didSet {
            layout = nil
            needsDisplay = true
        }
    }

    var position: Double = 0 {
        didSet {
            guard abs(position - oldValue) > 0.001 else { return }
            needsDisplay = true
        }
    }

    var style = TeleprompterAppearance() {
        didSet {
            guard style != oldValue else { return }
            layout = nil
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    /// The laid-out lines, rebuilt only when the text, the width or the font changes.
    private var layout: Layout?

    private struct Layout {
        let lines: [CTLine]
        /// Which script word each laid-out line starts at, for finding the reader's line.
        let firstWord: [Int]
        let lineHeight: CGFloat
        let width: CGFloat
        let fontSize: CGFloat

        /// Whether this layout is still the right one.
        ///
        /// Width compared with a tolerance because a resize can settle on a fraction of a
        /// point and rebuilding the whole script for that would be a full re-wrap on
        /// nothing.
        func matches(width: CGFloat, fontSize: CGFloat) -> Bool {
            abs(self.width - width) < 0.5 && self.fontSize == fontSize
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layout = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard !script.isEmpty else {
            drawPlaceholder(in: context)
            return
        }

        let layout = layoutIfNeeded()
        guard !layout.lines.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }

        if style.isMirrored {
            // Reading off a beam-splitter reverses the text, so the panel reverses it back.
            context.translateBy(x: bounds.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }

        // The reader's line is held at the middle and the text moves under it.
        let current = currentLineIndex(in: layout)
        let offset = bounds.midY - (CGFloat(current) + 0.5) * layout.lineHeight

        for (index, line) in layout.lines.enumerated() {
            let y = offset + CGFloat(index) * layout.lineHeight
            guard y > -layout.lineHeight, y < bounds.height + layout.lineHeight else { continue }

            // Read lines dim rather than disappear: somebody who loses their place looks
            // *back*, and a prompter that erases what it has passed cannot help them.
            let alpha = index < current ? style.pastOpacity : 1
            context.setAlpha(alpha)
            context.textPosition = CGPoint(x: 24, y: y + layout.lineHeight * 0.75)
            CTLineDraw(line, context)
        }
        context.setAlpha(1)
    }

    private func drawPlaceholder(in context: CGContext) {
        let text = "No script yet. Add one in Settings ▸ Recording."
        let font = CTFontCreateUIFontForLanguage(.system, 15, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): NSColor.secondaryLabelColor.cgColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (self.bounds.width - bounds.width) / 2,
            y: self.bounds.midY
        )
        CTLineDraw(line, context)
    }

    // MARK: - Layout

    private func layoutIfNeeded() -> Layout {
        if let layout, layout.matches(width: bounds.width, fontSize: style.fontSize) {
            return layout
        }
        let built = buildLayout()
        layout = built
        return built
    }

    /// Wraps the script to the panel's width, remembering where each line starts.
    ///
    /// Wrapped here rather than in the script, because where text wraps depends on the
    /// panel's width and the reader's font size — neither of which the script knows or
    /// should have an opinion about.
    private func buildLayout() -> Layout {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, style.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, style.fontSize, nil)
        let width = max(bounds.width - 48, 1)

        var lines: [CTLine] = []
        var firstWord: [Int] = []

        for line in script.lines {
            guard !line.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                lines.append(CTLineCreateWithAttributedString(NSAttributedString(string: " ")))
                firstWord.append(line.wordRange.lowerBound)
                continue
            }
            let attributed = NSAttributedString(string: line.text, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): NSColor.labelColor.cgColor
            ])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            let length = attributed.length
            while start < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                guard count > 0 else { break }
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                // Which word this wrapped line starts at, so the reader's position finds
                // the right one. Counted from the text before it rather than measured,
                // because the two must agree and the script's split is authoritative.
                let prefix = (line.text as NSString).substring(to: start)
                let consumed = prefix.split(whereSeparator: \.isWhitespace).count
                firstWord.append(line.wordRange.lowerBound + consumed)
                start += count
            }
        }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        return Layout(
            lines: lines,
            firstWord: firstWord,
            lineHeight: (ascent + descent + leading) * 1.35,
            width: bounds.width,
            fontSize: style.fontSize
        )
    }

    /// Which laid-out line the reader's word falls on.
    private func currentLineIndex(in layout: Layout) -> Int {
        let word = Int(position.rounded(.down))
        guard let index = layout.firstWord.lastIndex(where: { $0 <= word }) else { return 0 }
        return index
    }
}
