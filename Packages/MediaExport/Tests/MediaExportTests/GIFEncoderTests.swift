import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Shared
import Testing
@testable import MediaExport

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-gif-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a movie shaped like a screen recording: a mostly-static background with one
/// moving element, the way a window drag or a cursor moving over a document looks.
///
/// The distinction matters for the size budget. Full-frame noise is far harder to
/// compress than anything a screen recording contains, and tuning the encoder's defaults
/// to survive noise would make every real GIF needlessly small.
private func makeMovie(
    at url: URL,
    seconds: Double,
    width: Int,
    height: Int,
    frameRate: Int = 30,
    noisy: Bool = false
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frameCount = Int(seconds * Double(frameRate))
    for frame in 0 ..< frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let pool = adaptor.pixelBufferPool else { break }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { break }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            // A window-shaped block sliding across a flat background, plus faint texture
            // so the encoder is not handed a single flat colour.
            let blockX = (frame * 9) % max(1, width - 200)
            let blockY = height / 3
            for y in 0 ..< height {
                let inBlockRow = y >= blockY && y < blockY + 200
                for x in stride(from: 0, to: rowBytes, by: 4) {
                    let pixel = x / 4
                    let inBlock = inBlockRow && pixel >= blockX && pixel < blockX + 200
                    let value: UInt8 = if noisy {
                        UInt8((pixel + y + frame * 6) % 256)
                    } else if inBlock {
                        220
                    } else {
                        UInt8(40 + (y % 8))
                    }
                    bytes[y * rowBytes + x] = value
                    bytes[y * rowBytes + x + 1] = inBlock ? 180 : value
                    bytes[y * rowBytes + x + 2] = inBlock ? 90 : value
                    bytes[y * rowBytes + x + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(
            value: CMTimeValue(frame),
            timescale: CMTimeScale(frameRate)
        ))
    }

    input.markAsFinished()
    await writer.finishWriting()
}

private func fileSize(of url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

@Suite("GIF encoding", .serialized)
struct GIFEncoderTests {
    private let encoder = ImageIOGIFEncoder()

    @Test("A recording becomes a GIF that other software can read")
    func encodesAGIF() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("clip.mp4")
        try await makeMovie(at: movie, seconds: 1, width: 320, height: 240)

        let gif = try await encoder.encode(
            movieAt: movie,
            to: directory.appendingPathComponent("clip.gif"),
            options: GIFOptions(frameRate: 10, maximumWidth: 320)
        )

        #expect(fileSize(of: gif) > 0)
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.compuserve.gif")
        #expect(CGImageSourceGetCount(source) > 1, "a GIF of a moving clip should be animated")
    }

    @Test("The frame rate the caller asks for is the frame count they get")
    func honoursFrameRate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("clip.mp4")
        try await makeMovie(at: movie, seconds: 2, width: 240, height: 180)

        let gif = try await encoder.encode(
            movieAt: movie,
            to: directory.appendingPathComponent("clip.gif"),
            options: GIFOptions(frameRate: 5, maximumWidth: 240)
        )
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))

        // Two seconds at five frames a second.
        #expect(abs(CGImageSourceGetCount(source) - 10) <= 1)
    }

    @Test("The GIF is scaled down to the requested width")
    func honoursMaximumWidth() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("clip.mp4")
        try await makeMovie(at: movie, seconds: 1, width: 1280, height: 720)

        let gif = try await encoder.encode(
            movieAt: movie,
            to: directory.appendingPathComponent("clip.gif"),
            options: GIFOptions(frameRate: 5, maximumWidth: 400)
        )
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 400)
    }

    /// Doc 06 M13's acceptance criterion, measured.
    @Test("A ten-second 1080p clip exports under 12 MB", .timeLimit(.minutes(3)))
    func meetsSizeBudget() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("clip.mp4")
        try await makeMovie(at: movie, seconds: 10, width: 1920, height: 1080, frameRate: 30)

        let gif = try await encoder.encode(
            movieAt: movie,
            to: directory.appendingPathComponent("clip.gif"),
            options: GIFOptions()
        )

        let megabytes = Double(fileSize(of: gif)) / 1_048_576
        #expect(megabytes < 12, "a 10s 1080p clip produced \(String(format: "%.1f", megabytes)) MB")
        #expect(megabytes > 0.05, "that GIF is suspiciously small — did it encode anything?")
    }

    /// The pathological case, recorded rather than asserted on.
    ///
    /// Full-frame noise is far worse than any screen recording, and the default settings
    /// do go over budget on it. Knowing where the cliff is matters: it is the reason the
    /// export shows a size estimate first rather than discovering it afterwards.
    @Test("Full-frame noise is where the defaults stop fitting", .timeLimit(.minutes(3)))
    func noiseIsTheWorstCase() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("noise.mp4")
        try await makeMovie(at: movie, seconds: 3, width: 1920, height: 1080, frameRate: 30, noisy: true)

        let gif = try await encoder.encode(
            movieAt: movie,
            to: directory.appendingPathComponent("noise.gif"),
            options: GIFOptions()
        )
        let perSecond = Double(fileSize(of: gif)) / 1_048_576 / 3

        // Roughly 1.5 MB a second at the defaults; the estimate exists so this is visible
        // before a minute of encoding, not after.
        #expect(perSecond > 0.3, "noise should be expensive; measured \(perSecond) MB/s")
    }

    @Test("The estimate is in the right neighbourhood before committing to an export")
    func estimateIsUseful() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("clip.mp4")
        try await makeMovie(at: movie, seconds: 3, width: 640, height: 480)
        let options = GIFOptions(frameRate: 10, maximumWidth: 480)

        let estimate = try await encoder.estimatedSize(ofMovieAt: movie, options: options)
        let actual = try await fileSize(of: encoder.encode(
            movieAt: movie,
            to: directory.appendingPathComponent("clip.gif"),
            options: options
        ))

        // Rough by construction — GIF size depends on how much changes between frames —
        // but it has to be the difference between "about 2 MB" and a surprise.
        let ratio = Double(estimate) / Double(actual)
        #expect(ratio > 0.25 && ratio < 4, "estimate \(estimate) vs actual \(actual)")
    }

    @Test("A file with no video track is refused")
    func refusesNonVideo() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notAMovie = directory.appendingPathComponent("nope.mp4")
        try Data("not a movie".utf8).write(to: notAMovie)

        await #expect(throws: GIFError.self) {
            _ = try await encoder.encode(
                movieAt: notAMovie,
                to: directory.appendingPathComponent("out.gif"),
                options: GIFOptions()
            )
        }
    }

    @Test("Frame rate is capped at 50, which is all GIF can represent evenly")
    func capsFrameRate() {
        #expect(GIFOptions(frameRate: 120).frameRate == 50)
        #expect(GIFOptions(frameRate: 0).frameRate == 1)
        // Delays are stored in hundredths of a second.
        #expect(GIFOptions(frameRate: 10).frameDelay == 0.1)
    }
}
