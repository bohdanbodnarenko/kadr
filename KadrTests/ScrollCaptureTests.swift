import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import ImageIO
import KeyboardShortcuts
import SettingsKit
import Shared
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// The agent's half of scrolling capture (docs/03 §1.6).
///
/// The stitch itself is tested in VisionServices against golden pages; what belongs here
/// is the shell around it — the command, the preview strip, and the promise that the auto
/// tier is the only part that needs a new permission.
@MainActor
@Suite("Scrolling capture")
struct ScrollCaptureTests {
    @Test("Scrolling capture is a first-class command with a shortcut of its own")
    func commandExists() {
        #expect(CaptureCommand.allCases.contains(.captureScrolling))
        #expect(CaptureCommand.menuCommands.contains(.captureScrolling))
        #expect(CaptureCommand.captureScrolling.shortcutName.rawValue == "captureScrolling")
    }

    @Test("The assisted tier needs no permission beyond Screen Recording (docs/03 §1.6)")
    func assistedTierAsksForNothing() {
        // The only Accessibility ask in the whole feature is the auto tier's, and it is
        // reached from `AutoScroller` — never from the session that grabs the frames.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/CaptureCore/Sources/CaptureCore/ScrollCaptureSession.swift")
        guard let session = try? String(contentsOf: url, encoding: .utf8) else { return }
        #expect(!session.contains("AXIsProcessTrusted"))
    }

    @Test("The preview strip grows with each band and stays within its bounds")
    func previewStripGrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-strip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let frameSize = PixelSize(width: 400, height: 600)
        let url = try write(frame: frameSize, to: directory.appendingPathComponent("frame.png"))

        let strip = ScrollPreviewStrip()
        strip.begin(frameSize: frameSize)
        #expect(strip.image == nil)

        strip.append(frameAt: url, band: 0 ..< 600, frameExtent: 600)
        let first = try #require(strip.image)
        #expect(first.width == ScrollPreviewStrip.width)
        #expect(first.height == 300, "a 600 px frame at 400 px wide is half height in a 200 px strip")

        strip.append(frameAt: url, band: 400 ..< 600, frameExtent: 600)
        let second = try #require(strip.image)
        #expect(second.height == 400)
    }

    @Test("The strip stops growing rather than filling memory")
    func previewStripIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-strip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let frameSize = PixelSize(width: 200, height: 400)
        let url = try write(frame: frameSize, to: directory.appendingPathComponent("frame.png"))

        let strip = ScrollPreviewStrip()
        strip.begin(frameSize: frameSize)
        for _ in 0 ..< 40 {
            strip.append(frameAt: url, band: 0 ..< 400, frameExtent: 400)
        }
        let image = try #require(strip.image)
        #expect(image.height <= ScrollPreviewStrip.maximumHeight)
    }

    @Test("The horizontal preview strip grows with each band")
    func horizontalPreviewStripGrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-strip-h-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let frameSize = PixelSize(width: 600, height: 400)
        let url = try write(frame: frameSize, to: directory.appendingPathComponent("frame.png"))

        let strip = ScrollPreviewStrip()
        strip.begin(frameSize: frameSize, axis: .horizontal)
        strip.append(frameAt: url, band: 0 ..< 600, frameExtent: 600)
        let first = try #require(strip.image)
        #expect(first.height == ScrollPreviewStrip.fixedExtent)
        #expect(first.width == 300)

        strip.append(frameAt: url, band: 400 ..< 600, frameExtent: 600)
        let second = try #require(strip.image)
        #expect(second.width == 400)
    }

    @Test("Settle detection calls a still page settled and a moving one not")
    func settleDetection() {
        var detector = ScrollSettleDetector(requiredStillFrames: 2)
        let still = profile(scroll: 0)

        // One frame is not enough to decide: there is nothing to compare it against.
        var settled = detector.settled(with: still)
        #expect(settled == false)
        settled = detector.settled(with: still)
        #expect(settled == false)
        settled = detector.settled(with: still)
        #expect(settled)

        detector.reset()
        settled = detector.settled(with: profile(scroll: 0))
        #expect(settled == false)
        settled = detector.settled(with: profile(scroll: 60))
        #expect(settled == false)
    }

    // MARK: - Helpers

    private func profile(scroll: Int) -> RowProfile {
        let width = 64
        let height = 240
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var value = UInt64(bitPattern: Int64((scroll + y) &* 131 &+ x)) &+ 0x9E37_79B9_7F4A_7C15
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                pixels[y * width + x] = UInt8(truncatingIfNeeded: value >> 33)
            }
        }
        return pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return RowProfile(height: 0, values: []) }
            return RowProfile(grayscale: base, width: width, height: height, bytesPerRow: width)
        }
    }

    private func write(frame size: PixelSize, to url: URL) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

        guard let image = context.makeImage(),
              let sink = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
