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
        //
        // Fractional, not the line's index. Offsetting by whole lines would hold the text
        // still until the reader crossed into the next one and then jump it a whole line —
        // which is the stutter the continuous position exists to avoid, and it would make
        // every frame between two lines a redraw producing identical pixels.
        let current = currentLine(in: layout)
        let offset = bounds.midY - (current + 0.5) * layout.lineHeight

        // Only the lines that can be on screen. A prompter holds a whole script — a
        // thousand lines is an ordinary talk — and visiting all of them to reject all but
        // six is work repeated on every frame of a recording.
        let visible = visibleRange(offset: offset, lineHeight: layout.lineHeight, count: layout.lines.count)
        let currentIndex = Int(current)

        for index in visible {
            // Read lines dim rather than disappear: somebody who loses their place looks
            // *back*, and a prompter that erases what it has passed cannot help them.
            context.setAlpha(index < currentIndex ? style.pastOpacity : 1)
            context.textPosition = CGPoint(
                x: 24,
                y: offset + CGFloat(index) * layout.lineHeight + layout.lineHeight * 0.75
            )
            CTLineDraw(layout.lines[index], context)
        }
        context.setAlpha(1)
        drawProgress(in: context)
    }

    /// Which lines can appear, given where the text has scrolled to.
    ///
    /// Arithmetic rather than a filter: the answer is a contiguous run, and computing its
    /// ends costs the same whether the script is six lines or six thousand.
    private func visibleRange(offset: CGFloat, lineHeight: CGFloat, count: Int) -> Range<Int> {
        guard lineHeight > 0, count > 0 else { return 0 ..< 0 }
        let first = Int(((-lineHeight - offset) / lineHeight).rounded(.up))
        let last = Int(((bounds.height + lineHeight - offset) / lineHeight).rounded(.down))
        let lower = min(max(first, 0), count)
        let upper = min(max(last + 1, lower), count)
        return lower ..< upper
    }

    /// A thin bar showing how much of the script is left.
    ///
    /// Worth the few pixels: somebody reading aloud cannot see how far down the page they
    /// are, because the page moves under a fixed line. The bar is the only thing on the
    /// panel that answers "how much more".
    private func drawProgress(in context: CGContext) {
        let progress = script.progress(atWord: Int(position))
        let height: CGFloat = 3
        let track = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)

        context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor)
        context.fill(track)
        context.setFillColor(NSColor.controlAccentColor.cgColor)
        context.fill(CGRect(
            x: 0,
            y: track.minY,
            width: bounds.width * CGFloat(progress),
            height: height
        ))
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

    // MARK: - Seams

    /// How far the text has scrolled, for a test that cannot read pixels.
    var scrollOffsetForTesting: CGFloat {
        let layout = layoutIfNeeded()
        return bounds.midY - (currentLine(in: layout) + 0.5) * layout.lineHeight
    }

    /// Which lines would be drawn right now.
    ///
    /// Guarded the same way `draw` is: an empty script shows the placeholder and draws no
    /// lines at all, and a seam that reported otherwise would be describing a path that
    /// never runs.
    var visibleRangeForTesting: Range<Int> {
        guard !script.isEmpty else { return 0 ..< 0 }
        let layout = layoutIfNeeded()
        guard !layout.lines.isEmpty else { return 0 ..< 0 }
        let offset = bounds.midY - (currentLine(in: layout) + 0.5) * layout.lineHeight
        return visibleRange(offset: offset, lineHeight: layout.lineHeight, count: layout.lines.count)
    }

    /// Where the reader is, in lines, including the fraction through the current one.
    ///
    /// The fraction is what makes the scroll continuous: a reader halfway through a line's
    /// words is halfway between that line and the next, and the text is offset accordingly.
    private func currentLine(in layout: Layout) -> CGFloat {
        guard !layout.firstWord.isEmpty else { return 0 }
        let index = lineIndex(forWord: Int(position), in: layout)
        let start = layout.firstWord[index]
        let next = index + 1 < layout.firstWord.count ? layout.firstWord[index + 1] : start + 1
        let span = Double(max(next - start, 1))
        let within = min(max((position - Double(start)) / span, 0), 1)
        return CGFloat(index) + CGFloat(within)
    }

    /// Which laid-out line a word falls on.
    ///
    /// A binary search: `firstWord` is sorted by construction, this runs on every frame of
    /// a scroll, and a linear scan over a long script is the sort of cost that only shows
    /// up on the machine of somebody with a long script.
    private func lineIndex(forWord word: Int, in layout: Layout) -> Int {
        var low = 0
        var high = layout.firstWord.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if layout.firstWord[mid] <= word {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
