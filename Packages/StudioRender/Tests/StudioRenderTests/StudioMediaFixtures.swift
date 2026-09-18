import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Real movies and the means to read them back, shared by the renderer's suites.
///
/// Real files rather than mocks because what is worth checking about a render is
/// AVFoundation's behaviour — the length, the dimensions, the pictures in the frames — and
/// a mock would only confirm which methods the renderer calls.
enum StudioMediaFixtures {
    /// One frame's worth of colour, named so it does not become a three-member tuple.
    struct Colour {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        static let green = Colour(red: 0, green: 1, blue: 0)
    }

    /// The average colour of a frame.
    struct Average {
        let red: Double
        let green: Double
        let blue: Double
    }

    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-render-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A movie at 30 fps: halved red and blue by default, or flat in `colour`.
    ///
    /// Content rather than blank frames, because a renderer that reads nothing, writes
    /// black and reports success passes every test that only counts frames.
    static func makeMovie(
        seconds: Double,
        in folder: URL,
        named name: String = "screen.mov",
        size: CGSize = CGSize(width: 320, height: 180),
        colour: Colour? = nil,
        stacked: Bool = false,
        textPage: Bool = false
    ) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let source = try CIImage(cgImage: #require(
            textPage ? textPicture(size: size)
                : stacked ? stackedPicture(size: size) : picture(size: size, colour: colour)
        ))
        for frame in 0 ..< Int(seconds * 30) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            StudioRenderContext.shared.render(source, to: buffer, bounds: source.extent, colorSpace: nil)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// Lines of small dark text on white: what a screen recording mostly is, and the
    /// content where an encoder's rate control actually shows.
    private static func textPicture(size: CGSize) -> CGImage? {
        BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
            let attributes = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            ] as [NSAttributedString.Key: Any]
            var y = size.height - 16
            var line = 0
            while y > 0 {
                let text = "let value\(line) = compute(\(line * 7)) // a line of code, long enough to span the frame"
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 12, y: y)
                CTLineDraw(ctLine, context)
                y -= 14
                line += 1
            }
        }
    }

    /// Red over blue, top-left terms — the picture that catches a render drawn upside down,
    /// which the left-and-right default cannot.
    private static func stackedPicture(size: CGSize) -> CGImage? {
        BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            // A context draws bottom-up, so the top half is the one with the higher y.
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        }
    }

    private static func picture(size: CGSize, colour: Colour?) -> CGImage? {
        BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            if let colour {
                context.setFillColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
                context.fill(CGRect(origin: .zero, size: size))
            } else {
                context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
                context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
                context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
            }
        }
    }

    static func edit(
        zooms: [ZoomCue] = [],
        reframe: Reframe = .original,
        duration: TimeInterval
    ) -> StudioEdit {
        var edit = StudioEdit.untouched(duration: duration)
        edit.zooms = zooms
        edit.reframe = reframe
        return edit
    }

    // MARK: - Reading a movie back

    /// Every frame's bytes, so two renders can be compared and said how far apart they are.
    static func frameBytes(of url: URL, limit: Int = 40) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()

        var frames: [[UInt8]] = []
        while frames.count < limit, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(bytes(of: buffer))
        }
        reader.cancelReading()
        return frames
    }

    /// A copy of a pixel buffer's bytes.
    ///
    /// Copied out rather than read in place later: the buffer belongs to the sample buffer
    /// that produced it, and reading it after that has gone is the sort of bug that returns
    /// plausible numbers rather than crashing.
    static func bytes(of buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let count = CVPixelBufferGetHeight(buffer) * CVPixelBufferGetBytesPerRow(buffer)
        return [UInt8](UnsafeRawBufferPointer(start: base, count: count))
    }

    /// The mean absolute difference between two frames.
    ///
    /// The measure the determinism test needs: it separates "a different picture" from
    /// "the same picture, encoded twice", which differ by hundredths of a count.
    static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        let count = min(first.count, second.count)
        guard count > 0 else { return 0 }
        var total = 0
        for offset in 0 ..< count {
            total += abs(Int(first[offset]) - Int(second[offset]))
        }
        return Double(total) / Double(count)
    }

    /// The average colour of a rendered movie's first frame, as BGRA bytes.
    static func firstFrameColour(of url: URL) async throws -> Average {
        let frames = try await frameBytes(of: url, limit: 1)
        let pixels = try #require(frames.first)
        var blue = 0.0
        var green = 0.0
        var red = 0.0
        var count = 0.0
        for offset in stride(from: 0, to: pixels.count - 3, by: 4) {
            blue += Double(pixels[offset])
            green += Double(pixels[offset + 1])
            red += Double(pixels[offset + 2])
            count += 1
        }
        return Average(red: red / count, green: green / count, blue: blue / count)
    }
}

/// Collects progress values from the render's own context.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
