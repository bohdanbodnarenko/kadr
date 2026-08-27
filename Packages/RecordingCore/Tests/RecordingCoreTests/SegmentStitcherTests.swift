import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Shared
import Testing
@testable import RecordingCore

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-stitch-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a real MP4 of `frameCount` frames at 30 fps, so the stitcher is exercised
/// against files AVFoundation produced rather than fixtures.
private func makeMovie(at url: URL, frameCount: Int, size: Int = 160) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size,
        AVVideoHeightKey: size
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for frame in 0 ..< frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adaptor.pixelBufferPool else { break }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { break }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, frame % 2 == 0 ? 0x30 : 0xC0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }

    input.markAsFinished()
    await writer.finishWriting()
}

private func duration(of url: URL) async throws -> Double {
    try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))
}

@Suite("Stitching pause/resume segments", .serialized)
struct SegmentStitcherTests {
    private let stitcher = SegmentStitcher()

    @Test("Two segments join into one file whose length is their sum")
    func joinsSegments() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("a.mp4")
        let second = directory.appendingPathComponent("b.mp4")
        try await makeMovie(at: first, frameCount: 30) // 1 second
        try await makeMovie(at: second, frameCount: 15) // half a second

        let destination = directory.appendingPathComponent("joined.mp4")
        let result = try await stitcher.stitch([first, second], to: destination)

        let joined = try await duration(of: result)
        // Gapless: the time spent paused between the segments must not appear.
        #expect(abs(joined - 1.5) < 0.15, "joined length was \(joined)s, expected about 1.5s")
    }

    @Test("A single segment is moved rather than re-encoded")
    func singleSegmentIsMoved() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let segment = directory.appendingPathComponent("only.mp4")
        try await makeMovie(at: segment, frameCount: 30)
        let before = try await duration(of: segment)

        let destination = directory.appendingPathComponent("out.mp4")
        let result = try await stitcher.stitch([segment], to: destination)

        #expect(result == destination)
        #expect(FileManager.default.fileExists(atPath: segment.path) == false, "the segment should have moved")
        let after = try await duration(of: result)
        #expect(abs(after - before) < 0.01, "a single segment must be untouched")
    }

    @Test("Segments are consumed once they are joined")
    func cleansUpSegments() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("a.mp4")
        let second = directory.appendingPathComponent("b.mp4")
        try await makeMovie(at: first, frameCount: 10)
        try await makeMovie(at: second, frameCount: 10)

        _ = try await stitcher.stitch([first, second], to: directory.appendingPathComponent("joined.mp4"))

        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
    }

    @Test("Three segments join in the order they were recorded")
    func joinsThreeInOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var segments: [URL] = []
        for index in 0 ..< 3 {
            let url = directory.appendingPathComponent("s\(index).mp4")
            try await makeMovie(at: url, frameCount: 15)
            segments.append(url)
        }

        let result = try await stitcher.stitch(segments, to: directory.appendingPathComponent("joined.mp4"))
        let joined = try await duration(of: result)
        #expect(abs(joined - 1.5) < 0.2, "joined length was \(joined)s, expected about 1.5s")
    }

    @Test("Stitching nothing is an error rather than an empty file")
    func refusesEmptyInput() async {
        await #expect(throws: RecordingError.noFramesCaptured) {
            _ = try await SegmentStitcher().stitch([], to: URL(fileURLWithPath: "/tmp/nope.mp4"))
        }
    }
}
