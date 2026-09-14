import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

// swiftlint:disable file_length

/// Joins the frames of a scrolling capture into one tall image (docs/03 §1.6, docs/04 §4.4).
///
/// The shape of this is dictated by memory. A 30,000-pixel page is 140 MB of bitmap and
/// the frames that produced it are another 300 MB, so nothing is held that does not have
/// to be: frames are read one at a time from disk in both passes, and beyond a threshold
/// the output bitmap lives in a memory-mapped scratch file rather than on the heap.
///
/// Two passes, deliberately. The first works out where every frame belongs while holding
/// only the previous frame's row profile — a few hundred kilobytes. Only then is the final
/// height known, which is what lets the second pass allocate exactly once.
public struct ScrollStitcher: Sendable { // swiftlint:disable:this type_body_length
    private let logger = KadrLog.logger(.capture)

    public init() {}

    /// Where one frame's contribution lands in the finished strip.
    private struct Placement {
        let index: Int
        /// Rows of new content this frame brings.
        let offset: Int
        let confidence: Double
    }

    public enum Failure: Error, Sendable {
        case notEnoughFrames
        case unreadableFrame(Int)
        case inconsistentFrameSize
        case couldNotAllocate
        case couldNotWrite
    }

    /// Stitches `frames` into a single image at `destination`.
    public func stitch(
        frames: [URL],
        to destination: URL,
        axis: ScrollAxis = .vertical,
        memoryMappedThreshold: Int = 16000
    ) throws -> ScrollStitchResponse {
        guard frames.count >= 2 else { throw Failure.notEnoughFrames }

        let plan = try plan(frames: frames, axis: axis)
        let scrollExtent = axis == .vertical ? plan.totalHeight : plan.totalWidth
        let width = plan.width
        let height = plan.height

        let signpost = KadrLog.signposter(.capture)
        let state = signpost.beginInterval("scroll stitch")
        defer { signpost.endInterval("scroll stitch", state) }

        let canvas = try Canvas(
            width: width,
            height: height,
            memoryMapped: scrollExtent > memoryMappedThreshold
        )
        defer { canvas.dispose() }

        try draw(frames: frames, plan: plan, axis: axis, into: canvas)
        try write(canvas, to: destination)

        let size = "\(width)×\(height)"
        logger.info("Stitched \(frames.count, privacy: .public) frames into \(size, privacy: .public)")
        return ScrollStitchResponse(
            path: destination.path,
            pixelSize: PixelSize(width: width, height: height),
            seams: plan.seams,
            stickyHeader: plan.sticky.header,
            stickyFooter: plan.sticky.footer
        )
    }

    // MARK: - Pass one: where does everything go

    private struct Plan {
        let width: Int
        let height: Int
        let frameWidth: Int
        let frameHeight: Int
        let sticky: StickyBands
        let placements: [Placement]
        let totalHeight: Int
        let totalWidth: Int
        let seams: [ScrollSeam]
    }

    private func plan(frames: [URL], axis: ScrollAxis) throws -> Plan {
        switch axis {
        case .vertical:
            try planVertical(frames: frames)
        case .horizontal:
            try planHorizontal(frames: frames)
        }
    }

    private func planVertical(frames: [URL]) throws -> Plan {
        var previous: GrayscaleFrame?
        var sticky = StickyBands.none
        var stickyResolved = false
        var placements: [Placement] = []
        var seams: [ScrollSeam] = []
        var width = 0
        var frameHeight = 0
        var y = 0

        for (index, url) in frames.enumerated() {
            guard let frame = GrayscaleFrame(contentsOf: url) else {
                throw Failure.unreadableFrame(index)
            }
            if index == 0 {
                width = frame.width
                frameHeight = frame.height
            } else if frame.width != width || frame.height != frameHeight {
                throw Failure.inconsistentFrameSize
            }

            defer { previous = frame }
            guard let last = previous else {
                placements.append(Placement(index: index, offset: 0, confidence: 1))
                continue
            }

            let alignment = verticalAlignment(
                previous: last,
                current: frame,
                sticky: &sticky,
                stickyResolved: &stickyResolved
            )

            guard alignment.offset > 0 else { continue }

            y += alignment.offset
            placements.append(
                Placement(index: index, offset: alignment.offset, confidence: alignment.confidence)
            )
            seams.append(ScrollSeam(
                frameIndex: index,
                y: (frameHeight - sticky.footer) + y - alignment.offset,
                offset: alignment.offset,
                confidence: alignment.confidence
            ))
        }

        guard width > 0, frameHeight > 0 else { throw Failure.notEnoughFrames }
        let totalHeight = (frameHeight - sticky.footer) + y
        return Plan(
            width: width,
            height: totalHeight,
            frameWidth: width,
            frameHeight: frameHeight,
            sticky: sticky,
            placements: placements,
            totalHeight: totalHeight,
            totalWidth: width,
            seams: seams
        )
    }

    private func planHorizontal(frames: [URL]) throws -> Plan {
        var previous: GrayscaleFrame?
        var sticky = StickyBands.none
        var stickyResolved = false
        var placements: [Placement] = []
        var seams: [ScrollSeam] = []
        var frameWidth = 0
        var frameHeight = 0
        var x = 0

        for (index, url) in frames.enumerated() {
            guard let frame = GrayscaleFrame(contentsOf: url) else {
                throw Failure.unreadableFrame(index)
            }
            if index == 0 {
                frameWidth = frame.width
                frameHeight = frame.height
            } else if frame.width != frameWidth || frame.height != frameHeight {
                throw Failure.inconsistentFrameSize
            }

            defer { previous = frame }
            guard let last = previous else {
                placements.append(Placement(index: index, offset: 0, confidence: 1))
                continue
            }

            let alignment = horizontalAlignment(
                previous: last,
                current: frame,
                sticky: &sticky,
                stickyResolved: &stickyResolved
            )

            guard alignment.offset > 0 else { continue }

            x += alignment.offset
            placements.append(
                Placement(index: index, offset: alignment.offset, confidence: alignment.confidence)
            )
            seams.append(ScrollSeam(
                frameIndex: index,
                y: (frameWidth - sticky.footer) + x - alignment.offset,
                offset: alignment.offset,
                confidence: alignment.confidence
            ))
        }

        guard frameWidth > 0, frameHeight > 0 else { throw Failure.notEnoughFrames }
        let totalWidth = (frameWidth - sticky.footer) + x
        return Plan(
            width: totalWidth,
            height: frameHeight,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            sticky: sticky,
            placements: placements,
            totalHeight: frameHeight,
            totalWidth: totalWidth,
            seams: seams
        )
    }

    /// How far the page moved between two frames, resolving the chrome on the way.
    ///
    /// Chrome is found from the first pair that actually moved. Doing it on every pair
    /// would find a whole still frame "sticky" the moment the user pauses.
    private func verticalAlignment(
        previous: GrayscaleFrame,
        current: GrayscaleFrame,
        sticky: inout StickyBands,
        stickyResolved: inout Bool
    ) -> ScrollAlignment {
        var alignment = ScrollAligner.align(
            previous: previous.profile,
            current: current.profile,
            sticky: sticky
        )

        if !stickyResolved, alignment.offset > 0 {
            stickyResolved = true
            sticky = ScrollAligner.stickyBands(
                previous: previous.profile,
                current: current.profile,
                offset: alignment.offset
            )
            if sticky != .none {
                alignment = ScrollAligner.align(
                    previous: previous.profile,
                    current: current.profile,
                    sticky: sticky
                )
            }
        }

        // The row profile is a summary; when it is unsure, the pixels decide.
        guard alignment.confidence < ScrollAligner.confidenceThreshold else { return alignment }
        return verticalTemplateMatch(previous: previous, current: current, sticky: sticky) ?? alignment
    }

    private func horizontalAlignment(
        previous: GrayscaleFrame,
        current: GrayscaleFrame,
        sticky: inout StickyBands,
        stickyResolved: inout Bool
    ) -> ScrollAlignment {
        var alignment = ColumnAligner.align(
            previous: previous.columnProfile,
            current: current.columnProfile,
            sticky: sticky
        )

        if !stickyResolved, alignment.offset > 0 {
            stickyResolved = true
            sticky = ColumnAligner.stickyBands(
                previous: previous.columnProfile,
                current: current.columnProfile,
                offset: alignment.offset
            )
            if sticky != .none {
                alignment = ColumnAligner.align(
                    previous: previous.columnProfile,
                    current: current.columnProfile,
                    sticky: sticky
                )
            }
        }

        guard alignment.confidence < ColumnAligner.confidenceThreshold else { return alignment }
        return horizontalTemplateMatch(previous: previous, current: current, sticky: sticky) ?? alignment
    }

    /// The fallback when row profiles are not sure: match real pixels (docs/04 §4.4).
    ///
    /// Slower and narrower — it only searches near what the profiles suggested — but it
    /// looks at a band of actual pixels rather than a per-row summary, which is what
    /// separates two nearly identical lines of a Terminal scrollback.
    private func verticalTemplateMatch(
        previous: GrayscaleFrame,
        current: GrayscaleFrame,
        sticky: StickyBands
    ) -> ScrollAlignment? {
        let top = sticky.header
        let bottom = previous.height - sticky.footer
        let bodyHeight = bottom - top
        let band = min(96, bodyHeight / 4)
        guard band > 8 else { return nil }

        let maximumOffset = bodyHeight - band
        guard maximumOffset > 0 else { return nil }

        // The template is the band at the bottom of the previous frame's body; wherever it
        // reappears in the current frame is how far the page moved.
        let templateTop = bottom - band
        var scores = [Float](repeating: .greatestFiniteMagnitude, count: maximumOffset + 1)

        previous.pixels.withUnsafeBufferPointer { previousPixels in
            current.pixels.withUnsafeBufferPointer { currentPixels in
                guard let previousBase = previousPixels.baseAddress,
                      let currentBase = currentPixels.baseAddress else { return }
                for offset in 0 ... maximumOffset {
                    scores[offset] = meanAbsoluteDifference(
                        previousBase + templateTop * previous.bytesPerRow,
                        currentBase + (templateTop - offset) * current.bytesPerRow,
                        count: band * previous.bytesPerRow
                    )
                }
            }
        }

        guard let best = scores.indices.min(by: { scores[$0] < scores[$1] }) else { return nil }
        var rival = Float.greatestFiniteMagnitude
        for (offset, score) in scores.enumerated() where abs(offset - best) > 8 {
            rival = min(rival, score)
        }
        let separation = rival > 0 && rival < .greatestFiniteMagnitude
            ? Double(1 - scores[best] / rival)
            : 1
        return ScrollAlignment(
            offset: best,
            confidence: min(max(separation, 0), 1),
            overlappingRows: bodyHeight - best
        )
    }

    private func horizontalTemplateMatch(
        previous: GrayscaleFrame,
        current: GrayscaleFrame,
        sticky: StickyBands
    ) -> ScrollAlignment? {
        let leading = sticky.header
        let trailing = previous.width - sticky.footer
        let bodyWidth = trailing - leading
        let band = min(96, bodyWidth / 4)
        guard band > 8 else { return nil }

        let maximumOffset = bodyWidth - band
        guard maximumOffset > 0 else { return nil }

        let templateLeading = trailing - band
        var scores = [Float](repeating: .greatestFiniteMagnitude, count: maximumOffset + 1)

        previous.pixels.withUnsafeBufferPointer { previousPixels in
            current.pixels.withUnsafeBufferPointer { currentPixels in
                guard let previousBase = previousPixels.baseAddress,
                      let currentBase = currentPixels.baseAddress else { return }
                for offset in 0 ... maximumOffset {
                    var total: Float = 0
                    for y in 0 ..< previous.height {
                        total += meanAbsoluteDifference(
                            previousBase + y * previous.bytesPerRow + templateLeading,
                            currentBase + y * current.bytesPerRow + (templateLeading - offset),
                            count: band
                        )
                    }
                    scores[offset] = total / Float(previous.height)
                }
            }
        }

        guard let best = scores.indices.min(by: { scores[$0] < scores[$1] }) else { return nil }
        var rival = Float.greatestFiniteMagnitude
        for (offset, score) in scores.enumerated() where abs(offset - best) > 8 {
            rival = min(rival, score)
        }
        let separation = rival > 0 && rival < .greatestFiniteMagnitude
            ? Double(1 - scores[best] / rival)
            : 1
        return ScrollAlignment(
            offset: best,
            confidence: min(max(separation, 0), 1),
            overlappingRows: bodyWidth - best
        )
    }

    private func meanAbsoluteDifference(
        _ lhs: UnsafePointer<UInt8>,
        _ rhs: UnsafePointer<UInt8>,
        count: Int
    ) -> Float {
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: UnsafeBufferPointer(start: lhs, count: count), to: &left)
        vDSP.convertElements(of: UnsafeBufferPointer(start: rhs, count: count), to: &right)
        return vDSP.meanMagnitude(vDSP.subtract(left, right))
    }

    // MARK: - Pass two: draw it

    private func draw(frames: [URL], plan: Plan, axis: ScrollAxis, into canvas: Canvas) throws {
        switch axis {
        case .vertical:
            try drawVertical(frames: frames, plan: plan, into: canvas)
        case .horizontal:
            try drawHorizontal(frames: frames, plan: plan, into: canvas)
        }
    }

    private func drawVertical(frames: [URL], plan: Plan, into canvas: Canvas) throws {
        guard let context = canvas.context else { throw Failure.couldNotAllocate }
        let placements = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.index, $0) })
        let bodyBottom = plan.frameHeight - plan.sticky.footer
        let first = plan.placements.first?.index
        var y = 0

        for (index, url) in frames.enumerated() {
            guard let placement = placements[index] else { continue }
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
            else { throw Failure.unreadableFrame(index) }

            // The first frame brings its header and its whole body; every later one brings
            // only the rows that scrolled into view since the frame before it.
            let isFirst = index == first
            let bandHeight = isFirst ? bodyBottom : placement.offset
            let bandTop = isFirst ? 0 : bodyBottom - placement.offset

            // Everything above is measured from the top of the strip; a CGContext counts
            // from the bottom, so both rects flip here and nowhere else.
            let bandBottom = canvas.height - y - bandHeight
            let imageBottom = canvas.height - (y - bandTop) - plan.frameHeight

            context.saveGState()
            context.clip(to: CGRect(x: 0, y: bandBottom, width: plan.width, height: bandHeight))
            context.draw(image, in: CGRect(
                x: 0,
                y: imageBottom,
                width: plan.width,
                height: plan.frameHeight
            ))
            context.restoreGState()

            y += bandHeight
        }
    }

    private func drawHorizontal(frames: [URL], plan: Plan, into canvas: Canvas) throws {
        guard let context = canvas.context else { throw Failure.couldNotAllocate }
        let placements = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.index, $0) })
        let bodyTrailing = plan.frameWidth - plan.sticky.footer
        let first = plan.placements.first?.index
        var x = 0

        for (index, url) in frames.enumerated() {
            guard let placement = placements[index] else { continue }
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
            else { throw Failure.unreadableFrame(index) }

            let isFirst = index == first
            let bandWidth = isFirst ? bodyTrailing : placement.offset
            let bandLeading = isFirst ? 0 : bodyTrailing - placement.offset

            let bandLeadingX = x
            let imageLeadingX = x - bandLeading

            context.saveGState()
            context.clip(to: CGRect(
                x: bandLeadingX,
                y: 0,
                width: bandWidth,
                height: plan.height
            ))
            context.draw(image, in: CGRect(
                x: imageLeadingX,
                y: 0,
                width: plan.frameWidth,
                height: plan.height
            ))
            context.restoreGState()

            x += bandWidth
        }
    }

    // MARK: - Writing

    private func write(_ canvas: Canvas, to destination: URL) throws {
        guard let image = canvas.makeImage() else { throw Failure.couldNotWrite }
        guard let sink = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw Failure.couldNotWrite }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { throw Failure.couldNotWrite }
    }
}

// swiftlint:enable file_length
