import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import MediaExport

/// Trimming a recording (docs/03 §1.8, docs/07 M8, docs/09 U0.5).
///
/// Recording cards offered Save, Copy, GIF and Delete but no Trim, though the spec's card
/// is "Trim / Save / Copy / GIF / Delete" — so the one thing a screen recording almost
/// always needs, cutting the fumbling at each end, could not be done at all.
@Suite("Video trimmer")
struct VideoTrimmerTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-trim-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a real H.264 movie of `seconds` at 30 fps, so the export path is exercised
    /// end to end rather than mocked.
    private func makeMovie(seconds: Double, in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * 30)
        for frame in 0 ..< frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            // A changing grey level, so the frames are not all identical.
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func duration(of url: URL) async throws -> Double {
        try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))
    }

    // MARK: - The range arithmetic

    @Test("A range inside the recording is kept as it is")
    func rangeInside() throws {
        let range = try #require(TrimRange(start: 1, end: 3).clamped(to: 10))
        #expect(range.start == 1)
        #expect(range.end == 3)
        #expect(range.duration == 2)
    }

    @Test("A handle dragged past the end is clamped, not refused")
    func rangePastTheEnd() throws {
        let range = try #require(TrimRange(start: 2, end: 99).clamped(to: 10))
        #expect(range.end == 10)
    }

    @Test("An empty or inverted range is nothing to trim")
    func emptyRanges() {
        #expect(TrimRange(start: 4, end: 4).clamped(to: 10) == nil)
        #expect(TrimRange(start: 6, end: 2).clamped(to: 10) == nil)
        #expect(TrimRange(start: 0, end: 5).clamped(to: 0) == nil)
    }

    @Test("A range covering everything knows it is a no-op")
    func wholeRange() {
        #expect(TrimRange(start: 0, end: 10).isWhole(of: 10))
        #expect(!TrimRange(start: 1, end: 10).isWhole(of: 10))
    }

    // MARK: - Naming

    @Test("A trim is written beside the original, never over it")
    func destinationIsBesideTheOriginal() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Screen Recording.mov")
        try Data("movie".utf8).write(to: source)

        let destination = PassthroughVideoTrimmer.destination(trimming: source)
        #expect(destination.deletingLastPathComponent() == folder)
        #expect(destination.lastPathComponent == "Screen Recording (Trimmed).mov")
        #expect(destination != source)
    }

    @Test("A second trim of the same recording gets its own name")
    func destinationAvoidsCollisions() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Clip.mp4")
        try Data("movie".utf8).write(to: source)
        try Data("first".utf8).write(to: folder.appendingPathComponent("Clip (Trimmed).mp4"))

        #expect(PassthroughVideoTrimmer.destination(trimming: source).lastPathComponent
            == "Clip (Trimmed 2).mp4")
    }

    @Test("The container follows the destination's extension")
    func fileTypeFollowsExtension() {
        #expect(PassthroughVideoTrimmer.fileType(for: URL(fileURLWithPath: "/a/b.mov")) == .mov)
        #expect(PassthroughVideoTrimmer.fileType(for: URL(fileURLWithPath: "/a/b.mp4")) == .mp4)
        #expect(PassthroughVideoTrimmer.fileType(for: URL(fileURLWithPath: "/a/b.m4v")) == .m4v)
    }

    // MARK: - The export itself

    @Test("A trimmed recording is as long as the range asked for")
    func trimShortensTheMovie() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await makeMovie(seconds: 3, in: folder)
        #expect(try await duration(of: source) > 2.5)

        let destination = PassthroughVideoTrimmer.destination(trimming: source)
        let result = try await PassthroughVideoTrimmer().trim(
            movieAt: source,
            to: TrimRange(start: 1, end: 2),
            destination: destination
        )

        let trimmed = try await duration(of: result)
        // Passthrough cuts on key frames, so the result is close rather than exact.
        #expect(trimmed < 1.6, "the trim should be about a second, was \(trimmed)")
        #expect(trimmed > 0.2)
    }

    @Test("The original recording is left exactly as it was")
    func originalSurvives() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await makeMovie(seconds: 2, in: folder)
        let before = try Data(contentsOf: source)

        _ = try await PassthroughVideoTrimmer().trim(
            movieAt: source,
            to: TrimRange(start: 0.5, end: 1.5),
            destination: PassthroughVideoTrimmer.destination(trimming: source)
        )

        #expect(try Data(contentsOf: source) == before, "a trim must never touch the footage it came from")
    }

    @Test("Trimming over an existing file is refused")
    func refusesToOverwrite() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await makeMovie(seconds: 1, in: folder)
        let occupied = folder.appendingPathComponent("taken.mov")
        try Data("do not lose me".utf8).write(to: occupied)

        await #expect(throws: TrimError.self) {
            try await PassthroughVideoTrimmer().trim(
                movieAt: source,
                to: TrimRange(start: 0, end: 0.5),
                destination: occupied
            )
        }
        #expect(try Data(contentsOf: occupied) == Data("do not lose me".utf8))
    }

    @Test("A file that is not a movie is reported, not crashed into")
    func notAMovie() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: source)

        await #expect(throws: TrimError.noVideoTrack) {
            try await PassthroughVideoTrimmer().trim(
                movieAt: source,
                to: TrimRange(start: 0, end: 1),
                destination: folder.appendingPathComponent("out.mov")
            )
        }
    }

    @Test("An empty range is refused before anything is written")
    func emptyRangeIsRefused() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        await #expect(throws: TrimError.emptyRange) {
            try await PassthroughVideoTrimmer().trim(
                movieAt: source,
                to: TrimRange(start: 0.5, end: 0.5),
                destination: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
