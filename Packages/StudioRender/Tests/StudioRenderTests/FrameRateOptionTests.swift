import AVFoundation
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// The export's frame-rate option reaches the file (docs/17 T-STU-3).
///
/// Through the real session seam — manifest on disk, `render(session:…)`, a movie read
/// back by AVFoundation — because the bug was in that seam: the session path overwrote
/// the caller's rate with the manifest's, and every test that built a `Source` directly
/// passed.
@Suite("Studio renderer frame rate")
struct FrameRateOptionTests {
    private typealias Media = StudioMediaFixtures

    @Test("The caller's rate, capped at the recording's", arguments: [
        (recorded: 60, asked: 30, expected: 30),
        (recorded: 30, asked: 60, expected: 30),
        (recorded: 60, asked: 60, expected: 60)
    ])
    func nominalFrameRateFollowsTheOption(recorded: Int, asked: Int, expected: Int) async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        _ = try await Media.makeMovie(
            seconds: 1,
            in: session.directory,
            named: session.screenURL.lastPathComponent
        )
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 320, height: 180),
            frameRate: recorded,
            duration: 1
        ))
        let destination = folder.appendingPathComponent("out.mov")

        try await StudioRenderer().render(
            session: session,
            edit: Media.edit(duration: 1),
            to: destination,
            options: .init(codec: .h264, frameRate: asked)
        )

        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let rate = try await track.load(.nominalFrameRate)
        #expect(
            abs(Double(rate) - Double(expected)) < 2,
            "asked \(asked) of a \(recorded) fps recording, got \(rate)"
        )
    }

    @Test("Capping never raises the rate and ignores a missing manifest")
    func cappingIsPure() {
        let options = StudioRenderer.Options(frameRate: 24)
        #expect(StudioRenderer.capped(options, toSourceFrameRate: 60).frameRate == 24)
        #expect(StudioRenderer.capped(options, toSourceFrameRate: 15).frameRate == 15)
        #expect(StudioRenderer.capped(options, toSourceFrameRate: nil).frameRate == 24)
        #expect(StudioRenderer.capped(options, toSourceFrameRate: 0).frameRate == 24)
    }

    /// docs/17 T-STU-12: an untagged export is a guess for every player that opens it.
    @Test("The export is tagged BT.709")
    func exportIsColourTagged() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 0.5, in: folder)
        let destination = folder.appendingPathComponent("out.mov")
        try await StudioRenderer().render(
            StudioRenderer.Source(
                screen: movie,
                edit: Media.edit(duration: 0.5),
                pixelSize: CGSize(width: 320, height: 180)
            ),
            to: destination,
            options: .init(codec: .h264, frameRate: 30)
        )
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let primaries = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        )
        #expect(primaries as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    /// docs/18 Phase 4: wider colour is drawn in, and tagged as, Display P3.
    @Test("A wider-colour export is tagged P3")
    func widerColourIsTaggedP3() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 0.5, in: folder)
        let destination = folder.appendingPathComponent("out.mov")
        try await StudioRenderer().render(
            StudioRenderer.Source(
                screen: movie,
                edit: Media.edit(duration: 0.5),
                pixelSize: CGSize(width: 320, height: 180)
            ),
            to: destination,
            options: .init(codec: .h264, frameRate: 30, colorSpace: .displayP3)
        )
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let primaries = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        )
        #expect(primaries as? String == kCMFormatDescriptionColorPrimaries_P3_D65 as String)
    }
}
