import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
@testable import VisionServices

/// Stitching a scrolling capture (docs/03 §1.6 accept list, docs/04 §4.4).
@Suite("Scrolling capture stitcher")
struct ScrollStitcherTests {
    private func workingDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-stitch-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The largest per-channel difference between two images, and how many pixels differ.
    private func compare(_ lhs: CGImage, _ rhs: CGImage) -> (maximum: Int, differing: Int)? {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return nil }
        guard let left = GrayscaleFrame(lhs), let right = GrayscaleFrame(rhs) else { return nil }
        var maximum = 0
        var differing = 0
        for index in 0 ..< left.pixels.count {
            let difference = abs(Int(left.pixels[index]) - Int(right.pixels[index]))
            if difference > 0 {
                differing += 1
            }
            maximum = max(maximum, difference)
        }
        return (maximum, differing)
    }

    private func loadImage(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    @Test("The five cases from docs/03 §1.6 stitch back into the page they came from")
    func goldenCases() throws {
        for fixture in ScrollFixture.all {
            let directory = workingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let frames = try fixture.writeFrames(to: directory)
            let destination = directory.appendingPathComponent("stitched.png")
            let response = try ScrollStitcher().stitch(frames: frames, to: destination)

            let golden = fixture.golden()
            #expect(
                response.pixelSize == PixelSize(width: golden.width, height: golden.height),
                "\(fixture.name): stitched \(response.pixelSize), expected \(golden.width)×\(golden.height)"
            )

            let stitched = try #require(loadImage(destination))
            let difference = try #require(compare(stitched, golden), "\(fixture.name): size mismatch")
            // No duplicated or missing bands means every pixel lands where it started.
            #expect(difference.maximum == 0, "\(fixture.name): differs by \(difference.maximum)")
            #expect(difference.differing == 0, "\(fixture.name): \(difference.differing) pixels differ")
        }
    }

    @Test("Every scroll step is recovered exactly")
    func offsetsMatchTheScroll() throws {
        for fixture in ScrollFixture.all {
            let directory = workingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let frames = try fixture.writeFrames(to: directory)
            let response = try ScrollStitcher().stitch(
                frames: frames,
                to: directory.appendingPathComponent("stitched.png")
            )

            // A step of zero is the user pausing: it contributes no seam at all, because
            // repeating that band is exactly the duplicated-band failure to avoid.
            let expected = fixture.scrollSteps.filter { $0 > 0 }
            #expect(response.seams.map(\.offset) == expected, "\(fixture.name)")
        }
    }

    @Test("Chrome that does not scroll is kept once, not repeated")
    func stickyChromeIsFoundAndKeptOnce() throws {
        let directory = workingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = ScrollFixture.slack
        let frames = try fixture.writeFrames(to: directory)
        let response = try ScrollStitcher().stitch(
            frames: frames,
            to: directory.appendingPathComponent("stitched.png")
        )

        #expect(response.stickyHeader == fixture.header)
        #expect(response.stickyFooter == fixture.footer)
    }

    @Test("A clean stitch reports no seam worth showing the user")
    func confidentSeamsAreNotFlagged() throws {
        for fixture in ScrollFixture.all {
            let directory = workingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let frames = try fixture.writeFrames(to: directory)
            let response = try ScrollStitcher().stitch(
                frames: frames,
                to: directory.appendingPathComponent("stitched.png")
            )
            #expect(response.uncertainSeams.isEmpty, "\(fixture.name)")
        }
    }

    @Test("Fewer than two frames is not a scrolling capture")
    func refusesASingleFrame() throws {
        let directory = workingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = try ScrollFixture.safari.writeFrames(to: directory)

        #expect(throws: ScrollStitcher.Failure.self) {
            try ScrollStitcher().stitch(
                frames: Array(frames.prefix(1)),
                to: directory.appendingPathComponent("stitched.png")
            )
        }
    }
}
