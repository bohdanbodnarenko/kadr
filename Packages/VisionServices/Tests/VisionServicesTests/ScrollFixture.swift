import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The five scrolling-capture cases from docs/03 §1.6, built rather than recorded.
///
/// The accept list names Safari, VS Code, Slack, Finder and Terminal because each breaks
/// stitchers in a different way, and it is those *properties* the tests need — not the
/// pixels of any particular website. So each fixture is a synthetic page that reproduces
/// one failure mode exactly and deterministically: chrome that does not scroll, rows that
/// repeat on a fixed period, a pause mid-scroll, scroll steps that land on row boundaries.
/// A recorded video of Safari would test the same code less precisely and would rot the
/// first time Safari's toolbar changed height.
///
/// Being generated also means the golden output is known exactly, so the tests can assert
/// pixel equality rather than "looks about right".
struct ScrollFixture {
    let name: String
    let width: Int
    let frameHeight: Int
    /// Chrome that stays put: a toolbar, a tab bar, a message composer.
    let header: Int
    let footer: Int
    /// How far the page moved before each frame after the first. A zero is the user
    /// pausing, which must not put the same band in twice.
    let scrollSteps: [Int]
    /// Draws one row of page content into a BGRA row buffer.
    let drawRow: @Sendable (_ y: Int, _ row: UnsafeMutableBufferPointer<UInt8>, _ width: Int) -> Void

    var pageHeight: Int {
        // Enough page to satisfy every scroll step and still fill the last frame.
        scrollSteps.reduce(0, +) + frameHeight - header - footer
    }

    /// Where each frame starts in the page.
    var scrollPositions: [Int] {
        scrollSteps.reduce(into: [0]) { positions, step in
            positions.append(positions[positions.count - 1] + step)
        }
    }

    // MARK: - The five cases

    /// A long article: a toolbar that stays put, dense prose, and unhurried scrolling.
    static let safari = ScrollFixture(
        name: "Safari long page",
        width: 640,
        frameHeight: 520,
        header: 60,
        footer: 0,
        scrollSteps: [180, 240, 96, 300, 144, 210],
        drawRow: { y, row, width in
            fill(row, width: width, level: 250)
            // Paragraph lines, 22 px apart, with a ragged right edge.
            guard y % 22 < 11 else { return }
            let line = y / 22
            let length = 200 + Int(hash(UInt64(bitPattern: Int64(line))) % UInt64(width - 240))
            bar(row, from: 40, to: 40 + length, level: 40)
            if line % 9 == 0 {
                bar(row, from: 40, to: width - 40, level: 90)
            }
        }
    )

    /// A code editor: a tab bar, a gutter, and long runs of similar-looking lines.
    static let vsCode = ScrollFixture(
        name: "VS Code file",
        width: 720,
        frameHeight: 560,
        header: 40,
        footer: 24,
        scrollSteps: [126, 126, 252, 84, 168],
        drawRow: { y, row, width in
            fill(row, width: width, level: 30)
            bar(row, from: 0, to: 56, level: 45)
            guard y % 21 < 12 else { return }
            let line = y / 21
            // The gutter: a line number's worth of marks.
            bar(row, from: 20, to: 44, level: 110)
            // Indented code with a few coloured tokens.
            let indent = 64 + Int(hash(UInt64(bitPattern: Int64(line))) % 4) * 28
            let length = 120 + Int(hash(UInt64(bitPattern: Int64(line &* 7))) % 380)
            bar(row, from: indent, to: indent + length, level: 200)
            bar(row, from: indent, to: indent + 40, level: 150)
        }
    )

    /// A chat thread: a channel header, a composer pinned to the bottom, repeated avatars,
    /// and a pause while more messages load.
    static let slack = ScrollFixture(
        name: "Slack thread",
        width: 680,
        frameHeight: 600,
        header: 52,
        footer: 88,
        scrollSteps: [220, 0, 180, 260, 0, 140],
        drawRow: { y, row, width in
            fill(row, width: width, level: 252)
            let message = y / 76
            let inMessage = y % 76
            // Every message starts with the same avatar square — repetition on purpose.
            if inMessage < 36 {
                bar(row, from: 24, to: 60, level: 120)
                bar(row, from: 76, to: 76 + 90 + Int(hash(UInt64(bitPattern: Int64(message))) % 60), level: 30)
            }
            if inMessage >= 40, inMessage < 68 {
                let length = 160 + Int(hash(UInt64(bitPattern: Int64(message &* 3))) % UInt64(width - 260))
                bar(row, from: 76, to: 76 + length, level: 70)
            }
        }
    )

    /// A list view: fixed-height rows, alternating stripes, and scroll steps that land
    /// exactly on row boundaries. Nothing but the filenames tells one band from another.
    static let finder = ScrollFixture(
        name: "Finder list view",
        width: 600,
        frameHeight: 480,
        header: 30,
        footer: 0,
        scrollSteps: [96, 120, 96, 168, 120],
        drawRow: { y, row, width in
            let rowIndex = y / 24
            fill(row, width: width, level: rowIndex % 2 == 0 ? 255 : 244)
            guard y % 24 > 6, y % 24 < 18 else { return }
            bar(row, from: 16, to: 32, level: 150)
            let length = 60 + Int(hash(UInt64(bitPattern: Int64(rowIndex))) % 220)
            bar(row, from: 44, to: 44 + length, level: 40)
            bar(row, from: 400, to: 460, level: 120)
        }
    )

    /// Scrollback: uniform rows, most of them nearly identical, which is the case row
    /// profiles alone cannot resolve and the pixel fallback exists for.
    static let terminal = ScrollFixture(
        name: "Terminal scrollback",
        width: 640,
        frameHeight: 440,
        header: 0,
        footer: 0,
        scrollSteps: [102, 136, 68, 170, 102],
        drawRow: { y, row, width in
            fill(row, width: width, level: 16)
            guard y % 17 < 10 else { return }
            let line = y / 17
            // Every fifth line is the same prompt; the rest carry a little more.
            bar(row, from: 12, to: 40, level: 120)
            guard line % 5 != 0 else { return }
            let length = 80 + Int(hash(UInt64(bitPattern: Int64(line))) % 300)
            bar(row, from: 52, to: 52 + length, level: 190)
        }
    )

    static let all = [safari, vsCode, slack, finder, terminal]

    // MARK: - Rendering

    /// The whole page, as the stitcher should end up reproducing it.
    func page() -> CGImage {
        makeImage(width: width, height: pageHeight) { y, row in
            drawRow(y, row, width)
        }
    }

    /// What the screen showed at each scroll position, chrome included.
    func frames() -> [CGImage] {
        scrollPositions.map { scroll in
            makeImage(width: width, height: frameHeight) { y, row in
                if y < header {
                    chrome(row, y: y, level: 200)
                } else if y >= frameHeight - footer {
                    chrome(row, y: y, level: 210)
                } else {
                    drawRow(scroll + y - header, row, width)
                }
            }
        }
    }

    /// The stitch the tests are checking against: the chrome once, then the whole page
    /// that was scrolled through.
    func golden() -> CGImage {
        let contentHeight = (scrollPositions.last ?? 0) + frameHeight - header - footer
        return makeImage(width: width, height: header + contentHeight) { y, row in
            if y < header {
                chrome(row, y: y, level: 200)
            } else {
                drawRow(y - header, row, width)
            }
        }
    }

    /// Writes the frames out as PNGs, the way the agent hands them to the helper.
    func writeFrames(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try frames().enumerated().map { index, image in
            let url = directory.appendingPathComponent(String(format: "frame-%04d.png", index))
            guard let sink = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(sink, image, nil)
            guard CGImageDestinationFinalize(sink) else { throw CocoaError(.fileWriteUnknown) }
            return url
        }
    }

    // MARK: - Drawing primitives

    /// Chrome is deliberately identical in every frame: that is what makes it chrome.
    private func chrome(_ row: UnsafeMutableBufferPointer<UInt8>, y: Int, level: UInt8) {
        fill(row, width: width, level: level)
        Self.bar(row, from: 16, to: 16 + 40 + Int(Self.hash(UInt64(y)) % 120), level: 60)
    }

    private func fill(_ row: UnsafeMutableBufferPointer<UInt8>, width: Int, level: UInt8) {
        Self.fill(row, width: width, level: level)
    }

    private static func fill(_ row: UnsafeMutableBufferPointer<UInt8>, width: Int, level: UInt8) {
        for x in 0 ..< width {
            row[x * 4] = level
            row[x * 4 + 1] = level
            row[x * 4 + 2] = level
            row[x * 4 + 3] = 255
        }
    }

    private static func bar(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        from: Int,
        to: Int,
        level: UInt8
    ) {
        let upper = min(to, row.count / 4)
        guard from < upper else { return }
        for x in from ..< upper {
            row[x * 4] = level
            row[x * 4 + 1] = level
            row[x * 4 + 2] = level
            row[x * 4 + 3] = 255
        }
    }

    /// A stable hash, so a fixture renders identically on every machine and every run.
    /// `Hasher` is seeded per process and would make the goldens irreproducible.
    private static func hash(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    private func makeImage(
        width: Int,
        height: Int,
        row draw: (Int, UnsafeMutableBufferPointer<UInt8>) -> Void
    ) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0 ..< height {
                let start = y * bytesPerRow
                let row = UnsafeMutableBufferPointer(
                    rebasing: buffer[start ..< start + bytesPerRow]
                )
                draw(y, row)
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                      .union(.byteOrder32Little),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { fatalError("Could not build the fixture image") }
        return image
    }
}
