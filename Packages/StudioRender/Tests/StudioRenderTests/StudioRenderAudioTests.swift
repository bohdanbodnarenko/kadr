import AVFoundation
import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Exporting a recording that has sound (docs/09 U3.3).
///
/// Every other render test is silent, which left the whole audio half of the loop — the
/// interleaving, the drain after the last frame — without a single run.
@Suite("Studio renderer audio", .timeLimit(.minutes(1)))
struct StudioRenderAudioTests {
    private typealias Media = StudioMediaFixtures
    private let sourceSize = CGSize(width: 320, height: 180)

    private func render(videoSeconds: Double, audioSeconds: Double) async throws -> (URL, StudioRenderer.Output) {
        let folder = Media.scratch()
        let movie = try await Media.makeMovieWithAudio(
            seconds: videoSeconds,
            audioSeconds: audioSeconds,
            in: folder
        )
        let destination = folder.appendingPathComponent("out.mov")
        let output = try await StudioRenderer().render(
            StudioRenderer.Source(
                screen: movie,
                edit: Media.edit(duration: videoSeconds),
                pixelSize: sourceSize
            ),
            to: destination,
            options: .init(codec: .h264, frameRate: 30)
        )
        return (destination, output)
    }

    /// How much sound the finished file holds.
    private func soundLength(of url: URL) async throws -> Double {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return 0 }
        return try await CMTimeGetSeconds(track.load(.timeRange).duration)
    }

    @Test("A recording whose sound matches its picture renders, with the sound")
    func matchedAudio() async throws {
        let (url, output) = try await render(videoSeconds: 3, audioSeconds: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(output.frameCount > 80)
        let length = try await soundLength(of: url)
        #expect(abs(length - 3) < 0.3, "the export should carry all three seconds of sound, got \(length)")
    }

    @Test("Sound that outlasts the picture finishes, and is cut where the edit ends")
    func audioOutlastsTheVideo() async throws {
        let (url, _) = try await render(videoSeconds: 3, audioSeconds: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let length = try await soundLength(of: url)
        #expect(abs(length - 3) < 0.3, "the sound should end with the edit, got \(length)")
    }

    @Test("A recording whose sound stops early still finishes")
    func audioStopsEarly() async throws {
        let (url, output) = try await render(videoSeconds: 4, audioSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(output.frameCount > 100, "the picture should not stop with the sound, got \(output.frameCount)")
        let length = try await soundLength(of: url)
        #expect(abs(length - 2) < 0.3, "the sound should end where it ended, got \(length)")
    }
}
