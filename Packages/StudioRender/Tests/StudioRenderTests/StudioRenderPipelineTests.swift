import AVFoundation
import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// The staged export: what the split into decode, compose and write must not change
/// (docs/09 U3.3, docs/10 R0.4).
@Suite("Studio render pipeline")
struct StudioRenderPipelineTests {
    private typealias Media = StudioMediaFixtures
    private let sourceSize = CGSize(width: 320, height: 180)

    private func source(screen: URL, duration: TimeInterval) -> StudioRenderer.Source {
        StudioRenderer.Source(screen: screen, edit: Media.edit(duration: duration), pixelSize: sourceSize)
    }

    private var options: StudioRenderer.Options {
        .init(codec: .h264, frameRate: 30)
    }

    // MARK: - Progress

    @Test("Progress is throttled to half-percent steps and finishes exactly once")
    func progressThrottleTable() {
        struct Case {
            let name: String
            let inputs: [Double]
            let expected: [Double]
        }
        let cases = [
            Case(name: "nothing", inputs: [], expected: []),
            Case(
                name: "tiny steps are merged",
                inputs: [0.001, 0.002, 0.004, 0.006, 0.0105, 0.0115],
                expected: [0.001, 0.006, 0.0115]
            ),
            Case(name: "big steps all pass", inputs: [0.1, 0.2, 0.3], expected: [0.1, 0.2, 0.3]),
            Case(name: "finishing is always reported", inputs: [0.999, 0.9991, 1], expected: [0.999, 1]),
            Case(name: "and only once", inputs: [1, 1, 1], expected: [1]),
            Case(name: "nothing after finishing", inputs: [1, 0.5], expected: [1]),
            Case(name: "overshoot is finishing", inputs: [0.2, 1.4], expected: [0.2, 1])
        ]
        for testCase in cases {
            let (name, inputs, expected) = (testCase.name, testCase.inputs, testCase.expected)
            let recorder = ProgressRecorder()
            var throttle = StudioRenderer.ProgressThrottle { recorder.record($0) }
            for value in inputs {
                throttle.update(value)
            }
            #expect(recorder.values == expected, "\(name)")
        }
    }

    @Test("A render reports progress a few hundred times at most, not once a frame")
    func renderProgressIsThrottled() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 12, in: folder)
        let destination = folder.appendingPathComponent("out.mov")
        let recorder = ProgressRecorder()

        let output = try await StudioRenderer().render(
            source(screen: movie, duration: 12),
            to: destination,
            options: options,
            progress: { recorder.record($0) }
        )

        let values = recorder.values
        #expect(output.frameCount > 300)
        #expect(values.count <= 201, "\(values.count) reports")
        #expect(values.count < output.frameCount, "one report per frame is not throttled")
        #expect(values.last == 1)
        #expect(values.filter { $0 >= 1 }.count == 1, "finished was reported more than once")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "progress went backwards")
    }

    // MARK: - Cancellation

    /// Cancelled before a frame could be written, with nothing at the destination yet.
    @Test("A render cancelled before it starts leaves no file")
    func cancelledBeforeStart() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 3, in: folder)
        let destination = folder.appendingPathComponent("out.mov")
        let renderSource = source(screen: movie, duration: 3)
        let renderOptions = options

        let task = Task {
            // Cancelled before the render is even called, so the first check it reaches
            // throws — wherever in the pipeline that is.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StudioRenderer().render(renderSource, to: destination, options: renderOptions)
        }
        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path), "a cancelled export left a file")
    }

    /// Cancelled while frames are moving, over a file an earlier export left there.
    @Test("A render cancelled midway leaves no file, even where one used to be")
    func cancelledMidwayOverAnOldFile() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 20, in: folder)
        let destination = folder.appendingPathComponent("out.mov")
        try Data("an older export".utf8).write(to: destination)
        let renderSource = source(screen: movie, duration: 20)
        let renderOptions = options
        let recorder = ProgressRecorder()

        let task = Task {
            try await StudioRenderer().render(
                renderSource,
                to: destination,
                options: renderOptions,
                progress: { recorder.record($0) }
            )
        }
        // Cancelled once frames are demonstrably going in, rather than after a guess.
        let deadline = ContinuousClock.now + .seconds(10)
        while recorder.values.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            #expect(
                !FileManager.default.fileExists(atPath: destination.path),
                "a cancelled export left a partial movie behind"
            )
            return
        }
        // Finished before the cancellation landed: the file must then be the whole export.
        let length = try await CMTimeGetSeconds(AVURLAsset(url: destination).load(.duration))
        #expect(abs(length - 20) < 0.5)
    }

    // MARK: - Pixels

    /// The GPU stage draws through `CIRenderDestination` now; it must agree with the old
    /// synchronous render about which way up a pixel buffer is.
    @Test("The rendered movie is the right way up")
    func renderIsUpright() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder, stacked: true)
        let destination = folder.appendingPathComponent("out.mov")

        try await StudioRenderer().render(source(screen: movie, duration: 1), to: destination, options: options)

        let asset = AVURLAsset(url: destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let bytes = Media.bytes(of: buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        // BGRA: red is the third byte.
        let top = (red: bytes[bytesPerRow * 10 + 160 * 4 + 2], blue: bytes[bytesPerRow * 10 + 160 * 4])
        let bottomRow = bytesPerRow * (height - 10)
        let bottom = (red: bytes[bottomRow + 160 * 4 + 2], blue: bytes[bottomRow + 160 * 4])
        #expect(top.red > 200 && top.blue < 60, "the top of the movie is not red: \(top)")
        #expect(bottom.blue > 200 && bottom.red < 60, "the bottom of the movie is not blue: \(bottom)")
    }
}

/// The admission gate in front of every export.
@Suite("Export gate")
struct ExportGateTests {
    @Test("No more than the limit are admitted, and a released slot is handed on")
    func limitIsRespected() async throws {
        let gate = ExportGate(limit: 2)
        let order = ProgressRecorder()
        try await gate.acquire()
        try await gate.acquire()
        let waiters = (0 ..< 3).map { index in
            Task {
                try await gate.acquire()
                order.record(Double(index))
            }
        }
        while await gate.load.waiting < 3 {
            await Task.yield()
        }
        #expect(await gate.load == (running: 2, waiting: 3))
        #expect(order.values.isEmpty)

        await gate.release()
        #expect(await gate.load == (running: 2, waiting: 2), "a released slot was not handed on")
        await gate.release()
        await gate.release()
        for waiter in waiters {
            try await waiter.value
        }
        await gate.release()
        await gate.release()
        #expect(await gate.load == (running: 0, waiting: 0))
        #expect(order.values.count == 3)
    }

    @Test("A cancelled waiter leaves the queue without taking a slot")
    func cancelledWaiter() async throws {
        let gate = ExportGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        while await gate.load.waiting < 1 {
            await Task.yield()
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await gate.load == (running: 1, waiting: 0))
        await gate.release()
        #expect(await gate.load == (running: 0, waiting: 0))
    }
}
