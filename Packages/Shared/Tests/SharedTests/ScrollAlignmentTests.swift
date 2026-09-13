import Foundation
import Testing
@testable import Shared

/// Finding the scroll offset between two frames (docs/03 §1.6, docs/04 §4.4).
@Suite("Scroll alignment")
struct ScrollAlignmentTests {
    private let width = 200
    private let height = 400
    private let horizontalWidth = 400

    /// A stable pseudo-random level, so a test page renders the same everywhere.
    private func level(row: Int, column: Int) -> UInt8 {
        var value = UInt64(bitPattern: Int64(row &* 977 &+ column)) &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        return UInt8(truncatingIfNeeded: value >> 33)
    }

    /// A window onto a page starting at `scroll`, with optional unchanging chrome.
    private func profile(scroll: Int, header: Int = 0, footer: Int = 0) -> RowProfile {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let isChrome = y < header || y >= height - footer
                pixels[y * width + x] = isChrome
                    ? level(row: -1 - y, column: x)
                    : level(row: scroll + y - header, column: x)
            }
        }
        return profile(of: pixels)
    }

    /// Wraps a grayscale buffer, standing in for a captured frame.
    private func profile(of pixels: [UInt8]) -> RowProfile {
        pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return RowProfile(height: 0, values: []) }
            return RowProfile(grayscale: base, width: width, height: height, bytesPerRow: width)
        }
    }

    @Test("A page that scrolled reports how far", arguments: [1, 17, 120, 260])
    func findsTheOffset(scroll: Int) {
        let alignment = ScrollAligner.align(previous: profile(scroll: 0), current: profile(scroll: scroll))
        #expect(alignment.offset == scroll)
        #expect(alignment.confidence > ScrollAligner.confidenceThreshold)
    }

    @Test("A page that did not move reports nothing moved")
    func settledIsZero() {
        let alignment = ScrollAligner.align(previous: profile(scroll: 0), current: profile(scroll: 0))
        #expect(alignment.offset == 0)
    }

    @Test("Chrome that stays put is found and excluded")
    func findsStickyChrome() {
        let previous = profile(scroll: 0, header: 48, footer: 32)
        let current = profile(scroll: 150, header: 48, footer: 32)

        let rough = ScrollAligner.align(previous: previous, current: current)
        let sticky = ScrollAligner.stickyBands(previous: previous, current: current, offset: rough.offset)
        #expect(sticky.header == 48)
        #expect(sticky.footer == 32)

        let alignment = ScrollAligner.align(previous: previous, current: current, sticky: sticky)
        #expect(alignment.offset == 150)
        #expect(alignment.confidence > ScrollAligner.confidenceThreshold)
    }

    @Test("Two frames with nothing in common are not matched confidently")
    func repetitiveContentIsNotTrusted() {
        // Every row identical: any offset fits as well as any other, and saying so is the
        // whole point — the user gets a flagged seam instead of a silent wrong answer.
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                pixels[y * width + x] = level(row: y % 8, column: x)
            }
        }
        let flat = profile(of: pixels)
        let alignment = ScrollAligner.align(previous: flat, current: flat)
        #expect(alignment.confidence < ScrollAligner.confidenceThreshold)
    }

    @Test("Frames of different heights are refused rather than guessed at")
    func mismatchedHeights() {
        let short = RowProfile(height: 0, values: [])
        #expect(ScrollAligner.align(previous: short, current: profile(scroll: 0)).confidence == 0)
    }

    @Test("A page that scrolled horizontally reports how far", arguments: [1, 17, 120, 260])
    func findsTheHorizontalOffset(scroll: Int) {
        let alignment = ColumnAligner.align(
            previous: horizontalProfile(scroll: 0),
            current: horizontalProfile(scroll: scroll)
        )
        #expect(alignment.offset == scroll)
        #expect(alignment.confidence > ColumnAligner.confidenceThreshold)
    }

    @Test("A horizontal profile is one small vector per column")
    func horizontalProfileShape() {
        let profile = horizontalProfile(scroll: 0)
        #expect(profile.width == horizontalWidth)
        #expect(profile.values.count == horizontalWidth * ColumnProfile.bucketCount)
    }

    private func horizontalProfile(scroll: Int, leading: Int = 0, trailing: Int = 0) -> ColumnProfile {
        var pixels = [UInt8](repeating: 0, count: horizontalWidth * height)
        for y in 0 ..< height {
            for x in 0 ..< horizontalWidth {
                let isChrome = x < leading || x >= horizontalWidth - trailing
                pixels[y * horizontalWidth + x] = isChrome
                    ? level(row: y, column: -1 - x)
                    : level(row: y, column: scroll + x - leading)
            }
        }
        return pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return ColumnProfile(width: 0, values: []) }
            return ColumnProfile(
                grayscale: base,
                width: horizontalWidth,
                height: height,
                bytesPerRow: horizontalWidth
            )
        }
    }

    @Test("A profile is one small vector per row")
    func profileShape() {
        let profile = profile(scroll: 0)
        #expect(profile.height == height)
        #expect(profile.values.count == height * RowProfile.bucketCount)
    }
}
