import AVFoundation
import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

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

    /// Where a composition track's actual footage begins.
    ///
    /// The track's own `timeRange` starts at zero whatever is in it, because AVFoundation
    /// fills a leading gap with an empty segment — so a test that asks the track where it
    /// starts is asking the wrong object.
    private func firstFootageStart(of track: AVAssetTrack) async throws -> Double {
        let segments = try await track.load(.segments)
        guard let first = segments.first(where: { !$0.isEmpty }) else { return .infinity }
        return CMTimeGetSeconds(first.timeMapping.target.start)
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

    // MARK: - The camera's late start

    /// A capture session takes a moment to hand over its first frame — a third of a second
    /// built-in, well over a second on some external cameras — while the screen has been
    /// recording since before it was asked. Aligning both at zero puts the bubble
    /// permanently ahead of the picture by that much (docs/10 R0.5).
    @Test("A camera that started late is pushed back by its offset")
    func lateCameraIsAligned() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = try await makeMovie(seconds: 4, in: folder)
        let camera = try await makeMovie(seconds: 3, in: folder, named: "camera.mov")

        let composition = try await ClipCompositionBuilder().composition(
            for: .whole(duration: 4),
            screen: screen,
            camera: camera,
            cameraStartOffset: 1
        )
        let tracks = try await composition.loadTracks(withMediaType: .video)
        #expect(tracks.count == 2, "no camera track was added")

        // Asserted on the segments rather than the track's `timeRange`: AVFoundation
        // reports a composition track as beginning at zero and fills the gap with an empty
        // segment, so the track's range says nothing about where its footage sits.
        let start = try await firstFootageStart(of: tracks[1])
        #expect(abs(start - 1) < 0.2, "the camera's footage starts at \(start)s rather than 1s")
    }

    @Test("A camera with no offset still starts at the top")
    func promptCameraIsUnshifted() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = try await makeMovie(seconds: 3, in: folder)
        let camera = try await makeMovie(seconds: 3, in: folder, named: "camera.mov")

        let composition = try await ClipCompositionBuilder().composition(
            for: .whole(duration: 3),
            screen: screen,
            camera: camera
        )
        let tracks = try await composition.loadTracks(withMediaType: .video)
        let start = try await firstFootageStart(of: tracks[1])
        #expect(start < 0.2, "an on-time camera was shifted to \(start)s")
    }

    /// The drift the review found alongside it: the camera cursor used to advance by how
    /// much camera happened to be *available* rather than by the clip's own length, so one
    /// short camera file pulled every later segment early by the shortfall — and the bubble
    /// drifted further ahead of the picture for the rest of the recording.
    @Test("A short camera does not shift the segments that follow it")
    func shortCameraDoesNotShiftLaterSegments() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = try await makeMovie(seconds: 6, in: folder)
        // Two seconds of camera against six of screen: the first clip is fully covered,
        // the second only partly, and the third not at all.
        let camera = try await makeMovie(seconds: 2, in: folder, named: "camera.mov")

        let timeline = ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 2),
            Clip(sourceStart: 2, sourceDuration: 2),
            Clip(sourceStart: 4, sourceDuration: 2)
        ])
        let composition = try await ClipCompositionBuilder().composition(
            for: timeline,
            screen: screen,
            camera: camera
        )

        // The screen is unaffected by any of it: six seconds in, six seconds out.
        let length = try await duration(of: composition)
        #expect(abs(length - 6) < 0.3, "the screen came out at \(length)s")

        let tracks = try await composition.loadTracks(withMediaType: .video)
        let start = try await firstFootageStart(of: tracks[1])
        #expect(start < 0.2)
    }

    @Test("An imported soundtrack replaces the recording's own audio")
    func soundtrackReplacesScreenAudio() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await makeMovie(seconds: 3, in: folder)
        let wav = folder.appendingPathComponent("voice.wav")
        try writeSilentWav(seconds: 2, to: wav)

        let composition = try await ClipCompositionBuilder().composition(
            for: .whole(duration: 3),
            screen: movie,
            soundtrack: wav
        )
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "the soundtrack should be the only audio track")
        let length = try await duration(of: composition)
        #expect(abs(length - 3) < 0.2)
        let audioLength = try await CMTimeGetSeconds(tracks[0].load(.timeRange).duration)
        #expect(abs(audioLength - 2) < 0.2, "a shorter soundtrack ends early, got \(audioLength)")
    }

    /// A tiny PCM file, so the soundtrack path can be tested without a real recording.
    private func writeSilentWav(seconds: Double, to url: URL) throws {
        let sampleRate: UInt32 = 44100
        let samples = UInt32((seconds * Double(sampleRate)).rounded())
        let dataSize = samples * 2
        var data = Data()
        func ascii(_ text: String) {
            data.append(contentsOf: text.utf8)
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        u32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        ascii("data")
        u32(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
    }
}
