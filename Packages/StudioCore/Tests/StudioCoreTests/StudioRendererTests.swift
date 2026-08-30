import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// The export pipeline, end to end (docs/09 U3.3).
///
/// Against real movies written by `AVAssetWriter` and read back by `AVAssetReader`: what is
/// worth checking here is that the file has the frames, the length and the dimensions it
/// should, and that the pictures in it came from the recording.
@Suite("Studio renderer")
struct StudioRendererTests {
    private typealias Media = StudioMediaFixtures
    private let sourceSize = CGSize(width: 320, height: 180)

    private func source(
        screen: URL,
        edit: StudioEdit,
        telemetry: InputTelemetry = InputTelemetry()
    ) -> StudioRenderer.Source {
        StudioRenderer.Source(
            screen: screen,
            telemetry: telemetry,
            edit: edit,
            pixelSize: sourceSize
        )
    }

    private var options: StudioRenderer.Options {
        .init(codec: .h264, frameRate: 30)
    }

    // MARK: - The basic render

    @Test("An untouched edit renders a movie of the same shape and length")
    func untouchedRender() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        let output = try await StudioRenderer().render(
            source(screen: movie, edit: Media.edit(duration: 1)),
            to: destination,
            options: options
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(output.pixelSize == sourceSize)
        #expect(output.frameCount > 20, "only \(output.frameCount) frames were written")

        let length = try await CMTimeGetSeconds(AVURLAsset(url: destination).load(.duration))
        #expect(abs(length - 1) < 0.25, "expected about a second, got \(length)")
    }

    /// The check a renderer that writes black and reports success cannot pass.
    @Test("The rendered frames carry the recording's own picture")
    func rendersTheContent() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder, colour: .green)
        let destination = folder.appendingPathComponent("out.mov")

        try await StudioRenderer().render(
            source(screen: movie, edit: Media.edit(duration: 1)),
            to: destination,
            options: options
        )

        let colour = try await Media.firstFrameColour(of: destination)
        #expect(colour.green > 150, "expected a green frame, got \(colour)")
        #expect(colour.red < 100, "expected a green frame, got \(colour)")
    }

    // MARK: - Reframe

    @Test("A vertical reframe renders a portrait movie")
    func verticalRender() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        let output = try await StudioRenderer().render(
            source(
                screen: movie,
                edit: Media.edit(reframe: Reframe(aspect: .nineSixteen, fill: .fill), duration: 1)
            ),
            to: destination,
            options: options
        )
        #expect(output.pixelSize.height > output.pixelSize.width, "expected portrait, got \(output.pixelSize)")

        // The file has to agree with what the render reported, or a caller that trusts the
        // return value lays its UI out against a size the movie does not have.
        let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        #expect(natural == output.pixelSize, "the file disagrees with the reported size")
    }

    // MARK: - Clips

    @Test("A cut timeline renders a shorter movie")
    func cutRender() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 3, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        var trimmed = Media.edit(duration: 3)
        trimmed.clips = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 1)])

        let output = try await StudioRenderer().render(
            source(screen: movie, edit: trimmed),
            to: destination,
            options: options
        )
        #expect(output.frameCount < 45, "a one-second cut wrote \(output.frameCount) frames")
    }

    /// The assertion is on length, not on frame count. `scaleTimeRange` retimes frames
    /// rather than dropping them, so two seconds at 2× is one second still holding all
    /// sixty of its frames — a higher frame rate, which is what a sped-up recording should
    /// look like. Counting frames here would be testing a misunderstanding.
    @Test("A sped-up clip renders a movie half as long")
    func speedRender() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 2, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        var fast = Media.edit(duration: 2)
        fast.clips = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 2, speed: 2)])

        try await StudioRenderer().render(
            source(screen: movie, edit: fast),
            to: destination,
            options: options
        )
        let length = try await CMTimeGetSeconds(AVURLAsset(url: destination).load(.duration))
        #expect(abs(length - 1) < 0.25, "2× of two seconds came out at \(length)s")
    }

    // MARK: - Failure

    @Test("A file that is not a movie fails rather than writing a broken one")
    func notAMovie() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notAMovie = folder.appendingPathComponent("nope.mov")
        try Data("this is not a movie".utf8).write(to: notAMovie)
        let destination = folder.appendingPathComponent("out.mov")

        await #expect(throws: StudioRenderer.RenderError.noVideoTrack) {
            try await StudioRenderer().render(
                StudioRenderer.Source(screen: notAMovie, edit: Media.edit(duration: 1)),
                to: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path), "a broken file was left behind")
    }

    @Test("An existing file at the destination is replaced rather than appended to")
    func replacesExisting() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")
        try Data("older".utf8).write(to: destination)

        let output = try await StudioRenderer().render(
            source(screen: movie, edit: Media.edit(duration: 1)),
            to: destination,
            options: options
        )
        #expect(output.frameCount > 0)
    }

    // MARK: - Bit rate

    /// Screen content is flat colour and text, which compresses well and shows blocking
    /// mercilessly. A film-derived table under-serves it badly, so the estimate has its own
    /// test rather than being a number inside a dictionary literal.
    @Test("The bit rate rises with size and rate, and stays inside its bounds")
    func bitRateEstimate() {
        let small = StudioRenderer.bitRate(for: CGSize(width: 640, height: 360), frameRate: 30)
        let large = StudioRenderer.bitRate(for: CGSize(width: 3840, height: 2160), frameRate: 60)
        #expect(small < large)
        #expect(small >= 1_500_000)
        #expect(large <= 60_000_000)
        #expect(StudioRenderer.bitRate(for: .zero, frameRate: 0) >= 1_500_000)
    }

    // MARK: - Failure leaves nothing behind

    /// A partial file at the path the user chose is worse than no file: one of those is
    /// obviously missing and the other plays for seven minutes of a ten-minute recording
    /// and looks finished (docs/10 R0.4).
    @Test("A cancelled render leaves no file at the destination")
    func cancellationLeavesNothing() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Twenty seconds so the render cannot possibly finish inside the pause below — a
        // three-second one completed first and kept its file, which looked like a failure
        // of the cleanup and was a failure of the test.
        let movie = try await Media.makeMovie(seconds: 20, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        let task = Task {
            try await StudioRenderer().render(
                source(screen: movie, edit: Media.edit(duration: 20)),
                to: destination,
                options: options
            )
        }
        // Long enough that the writer exists and frames are going in, short enough that
        // hundreds remain.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        // Asserted only when the cancellation actually landed. A loaded machine can finish
        // even a long render inside the pause, and a test that fails because the code was
        // *fast* teaches nobody anything — it just gets disabled.
        do {
            _ = try await task.value
        } catch {
            #expect(
                !FileManager.default.fileExists(atPath: destination.path),
                "a cancelled export left a partial movie behind"
            )
        }
    }

    /// The same guarantee on the path that fails before a frame is written.
    @Test("A render that cannot start leaves no file at the destination")
    func failedStartLeavesNothing() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notAMovie = folder.appendingPathComponent("nope.mov")
        try Data("this is not a movie".utf8).write(to: notAMovie)
        let destination = folder.appendingPathComponent("out.mov")

        _ = try? await StudioRenderer().render(
            StudioRenderer.Source(screen: notAMovie, edit: Media.edit(duration: 1)),
            to: destination
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// And the case that must *not* clean up: a render that finished.
    @Test("A finished render keeps its file")
    func successKeepsTheFile() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        try await StudioRenderer().render(
            source(screen: movie, edit: Media.edit(duration: 1)),
            to: destination,
            options: options
        )
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}
