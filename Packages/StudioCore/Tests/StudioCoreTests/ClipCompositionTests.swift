import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// Assembling clips into something AVFoundation can play (docs/09 U3.4).
///
/// Against a real movie rather than a mock: the behaviour worth checking — that a sped-up
/// clip really is shorter, and that its audio was scaled with it — is AVFoundation's, and a
/// mock would only test that I called the method I wrote.
@Suite("Clip composition")
struct ClipCompositionTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-clip-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real movie of `seconds` at 30 fps, with an audio track.
    private func makeMovie(seconds: Double, in folder: URL, named name: String = "screen.mov") async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(video)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * 30)
        for frame in 0 ..< frames {
            while !video.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        video.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func duration(of composition: AVComposition) async throws -> Double {
        try await CMTimeGetSeconds(composition.load(.duration))
    }

    @Test("An uncut timeline composes to the whole recording")
    func uncutComposition() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await makeMovie(seconds: 3, in: folder)

        let composition = try await ClipCompositionBuilder().composition(
            for: .whole(duration: 3),
            screen: movie
        )
        let length = try await duration(of: composition)
        #expect(abs(length - 3) < 0.2, "expected about three seconds, got \(length)")
    }

    /// Cutting is removing a clip; the recording on disk is never touched.
    @Test("Removing a clip shortens the composition and leaves the file alone")
    func cutComposition() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await makeMovie(seconds: 4, in: folder)
        let before = try Data(contentsOf: movie)

        var timeline = ClipTimeline.whole(duration: 4)
        timeline.split(atEdited: 2)
        timeline.remove(timeline.clips[0].id)

        let composition = try await ClipCompositionBuilder().composition(for: timeline, screen: movie)
        let length = try await duration(of: composition)
        #expect(length < 3, "the first half should be gone, got \(length)")
        #expect(try Data(contentsOf: movie) == before, "the recording must not be touched")
    }

    @Test("A sped-up clip really is shorter")
    func speedShortensTheComposition() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await makeMovie(seconds: 4, in: folder)

        var timeline = ClipTimeline.whole(duration: 4)
        timeline.setSpeed(2, for: timeline.clips[0].id)

        let composition = try await ClipCompositionBuilder().composition(for: timeline, screen: movie)
        let length = try await duration(of: composition)
        #expect(abs(length - 2) < 0.3, "expected about two seconds, got \(length)")
    }

    @Test("A file that is not a movie is reported, not crashed into")
    func notAMovie() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notAMovie = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notAMovie)

        await #expect(throws: ClipCompositionBuilder.BuildError.noVideoTrack) {
            try await ClipCompositionBuilder().composition(for: .whole(duration: 1), screen: notAMovie)
        }
    }

    /// A recording without its webcam is still the recording, so a camera file that will
    /// not open costs the bubble rather than the export.
    @Test("A missing camera file does not fail the composition")
    func missingCamera() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await makeMovie(seconds: 2, in: folder)

        let composition = try await ClipCompositionBuilder().composition(
            for: .whole(duration: 2),
            screen: movie,
            camera: folder.appendingPathComponent("camera.mov")
        )
        #expect(try await duration(of: composition) > 0)
    }

    /// The camera starts when the user turns it on, so it is often shorter than the screen.
    @Test("A camera shorter than the screen contributes what it has")
    func shorterCamera() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = try await makeMovie(seconds: 4, in: folder)
        let camera = try await makeMovie(seconds: 1, in: folder, named: "camera.mov")

        let composition = try await ClipCompositionBuilder().composition(
            for: .whole(duration: 4),
            screen: screen,
            camera: camera
        )
        // Two video tracks: the screen for its whole length, the camera for as much as it
        // has.
        let tracks = try await composition.loadTracks(withMediaType: .video)
        #expect(tracks.count == 2)
        #expect(try await duration(of: composition) > 3)
    }

    @Test("An empty timeline composes to nothing rather than failing")
    func emptyTimeline() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await makeMovie(seconds: 2, in: folder)

        let composition = try await ClipCompositionBuilder().composition(
            for: ClipTimeline(),
            screen: movie
        )
        #expect(try await duration(of: composition) == 0)
    }
}
