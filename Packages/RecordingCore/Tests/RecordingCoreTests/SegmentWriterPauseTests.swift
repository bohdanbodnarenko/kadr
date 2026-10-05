import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import RecordingCore

/// Pause and resume through a real `SegmentWriter` (docs/17 T-REC-1).
///
/// The engine's other tests use a fake writer, which is exactly why they could not see the
/// bug: the held frame re-appended on resume carried its pre-pause time, so the segment's
/// session began before the pause and the pause was written back in as a frozen frame.
@Suite("Segment writer across a pause")
struct SegmentWriterPauseTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pause-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func frame(at seconds: Double, kind: SampleBufferBox.Kind = .video) throws -> SampleBufferBox {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
        )
        let image = try #require(status == kCVReturnSuccess ? pixelBuffer : nil)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format
        )
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        try CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            formatDescription: #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return try SampleBufferBox(buffer: #require(sample), kind: kind)
    }

    private func fileDuration(_ url: URL) async throws -> Double {
        try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))
    }

    /// The seconds spent paused must not be in either segment, and the engine's running
    /// length — what the studio's telemetry is aligned against — must agree with them.
    @Test("A 2 s pause adds nothing to the recording")
    func pauseIsNotWritten() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions()
        options.capturesSystemAudio = false
        options.capturesMicrophone = false

        let factory: SegmentWriterFactory = { url, width, height, options in
            try SegmentWriter(fileURL: url, pixelWidth: width, pixelHeight: height, options: options)
        }
        let engine = RecordingEngine(makeWriter: factory)
        let first = try factory(directory.appendingPathComponent("segment-0.mp4"), 100, 100, options)
        await engine.primeForTesting(state: .recording, segments: [], sessionDirectory: directory, writer: first)

        for time in stride(from: 10.0, through: 11.0, by: 0.1) {
            try await engine.deliverForTesting(frame(at: time))
            // A real-time input refuses frames it has not caught up with; pace like SCK.
            try await Task.sleep(for: .milliseconds(15))
        }
        try await engine.pause()
        // Frames keep arriving while paused and are dropped.
        try await engine.deliverForTesting(frame(at: 12.0))
        try await engine.resume()

        // A static screen after the resume: only an idle (clock) sample, then pictures.
        try await engine.deliverForTesting(frame(at: 13.0, kind: .clock))
        for time in stride(from: 13.1, through: 14.0, by: 0.1) {
            try await engine.deliverForTesting(frame(at: time))
            // A real-time input refuses frames it has not caught up with; pace like SCK.
            try await Task.sleep(for: .milliseconds(15))
        }
        try await engine.pause()

        let segments = await engine.segmentsForTesting
        try #require(segments.count == 2)
        let resumed = try await fileDuration(segments[1])
        #expect(resumed < 1.5, "the resumed segment is \(resumed) s; the 2 s pause was written into it")
        #expect(resumed > 0.5, "the resumed segment lost its pictures: \(resumed) s")

        let total = await engine.accumulatedDurationForTesting
        #expect(abs(total - 2.0) < 0.2, "engine length \(total) s should be the 2 s actually recorded")
    }

    /// docs/18 REC-6: the stream keeps running while paused, and a resume must open on
    /// the screen as it is then, not on the picture from the moment of Pause.
    @Test("Frames seen while paused become the held frame")
    func heldFrameTracksPause() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions()
        options.capturesSystemAudio = false
        options.capturesMicrophone = false
        let factory: SegmentWriterFactory = { url, width, height, options in
            try SegmentWriter(fileURL: url, pixelWidth: width, pixelHeight: height, options: options)
        }
        let engine = RecordingEngine(makeWriter: factory)
        let first = try factory(directory.appendingPathComponent("segment-0.mp4"), 100, 100, options)
        await engine.primeForTesting(state: .recording, segments: [], sessionDirectory: directory, writer: first)

        try await engine.deliverForTesting(frame(at: 10.0))
        try await engine.pause()
        try await engine.deliverForTesting(frame(at: 12.0))

        let held = try #require(await engine.heldFrameTimeForTesting)
        #expect(abs(CMTimeGetSeconds(held) - 12.0) < 0.001)
    }

    /// docs/18 REC-3: a still screen sends only idle ticks, which carry no picture. The
    /// file must still last until the last tick, not end at the last new frame.
    @Test("A still ending lasts until the segment closes")
    func stillTailSurvivesClose() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions()
        options.capturesSystemAudio = false
        options.capturesMicrophone = false

        let factory: SegmentWriterFactory = { url, width, height, options in
            try SegmentWriter(fileURL: url, pixelWidth: width, pixelHeight: height, options: options)
        }
        let engine = RecordingEngine(makeWriter: factory)
        let first = try factory(directory.appendingPathComponent("segment-0.mp4"), 100, 100, options)
        await engine.primeForTesting(state: .recording, segments: [], sessionDirectory: directory, writer: first)

        for time in stride(from: 10.0, through: 11.0, by: 0.1) {
            try await engine.deliverForTesting(frame(at: time))
            try await Task.sleep(for: .milliseconds(15))
        }
        // Four still seconds: idle ticks only.
        for time in stride(from: 12.0, through: 15.0, by: 1.0) {
            try await engine.deliverForTesting(frame(at: time, kind: .clock))
        }
        try await engine.pause()

        let segments = await engine.segmentsForTesting
        let segment = try #require(segments.first)
        let length = try await fileDuration(segment)
        #expect(length > 4.8, "the still tail was cut: \(length) s, expected about 5 s")
    }
}
