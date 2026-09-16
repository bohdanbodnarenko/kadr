import AVFoundation
import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// The studio player against a real movie (docs/10 R1.1).
@MainActor
@Suite("Studio playback controller")
struct StudioPlaybackControllerTests {
    private func ready(seconds: Double = 2) async throws -> (StudioDocumentModel, URL) {
        let folder = StudioPlaybackFixtures.scratch()
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: seconds)
        studio.previewPlayback.update()
        let built = try await StudioPlaybackFixtures.wait {
            !studio.playback.isBuilding && studio.playback.player?.currentItem != nil
        }
        #expect(built, "the preview never built a player item")
        return (studio, folder)
    }

    @Test("The first build installs an item and the picture size")
    func firstBuildInstallsAnItem() async throws {
        let (studio, folder) = try await ready()
        defer {
            studio.stopPlayback()
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(studio.playback.outputSize == StudioPlaybackFixtures.movieSize)
        #expect(studio.playback.player?.allowsExternalPlayback == false)
        #expect(!studio.isPlaying)
    }

    /// Dragging a slider must not tear down the decoder: the item stays, only its video
    /// composition changes.
    @Test("A picture change keeps the player item")
    func pictureChangeKeepsTheItem() async throws {
        let (studio, folder) = try await ready()
        defer {
            studio.stopPlayback()
            try? FileManager.default.removeItem(at: folder)
        }
        let item = try #require(studio.playback.player?.currentItem)
        let before = item.videoComposition

        studio.change { $0.showsCursor.toggle() }
        studio.previewPlayback.update()
        try await StudioPlaybackFixtures.wait { !studio.playback.isBuilding }

        #expect(studio.playback.player?.currentItem === item)
        #expect(item.videoComposition !== before, "the new composer never reached the item")
    }

    @Test("A cut replaces the player item")
    func cutReplacesTheItem() async throws {
        let (studio, folder) = try await ready()
        defer {
            studio.stopPlayback()
            try? FileManager.default.removeItem(at: folder)
        }
        let item = try #require(studio.playback.player?.currentItem)

        studio.change { $0.clips = ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: 1)]) }
        studio.previewPlayback.update()
        try await StudioPlaybackFixtures.wait { !studio.playback.isBuilding }

        let replaced = try #require(studio.playback.player?.currentItem)
        #expect(replaced !== item)
        let duration = try await replaced.asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.05, "the new item plays \(duration)s, not the 1s cut")
    }

    @Test("Hovering the timeline produces a small thumbnail, and leaving clears it")
    func skimProducesAThumbnail() async throws {
        let (studio, folder) = try await ready()
        defer {
            studio.stopPlayback()
            try? FileManager.default.removeItem(at: folder)
        }
        studio.playback.skim(at: 0.5)
        let shown = try await StudioPlaybackFixtures.wait { studio.playback.skimImage != nil }
        #expect(shown, "no skim thumbnail arrived")
        let image = try #require(studio.playback.skimImage)
        #expect(max(image.width, image.height) <= StudioPreviewSize.skimLongestEdge)

        studio.playback.skim(at: nil)
        #expect(studio.playback.skimImage == nil)
    }

    @Test("There is no skim thumbnail while playing")
    func noSkimWhilePlaying() async throws {
        let (studio, folder) = try await ready()
        defer {
            studio.stopPlayback()
            try? FileManager.default.removeItem(at: folder)
        }
        studio.play()
        studio.playback.skim(at: 0.5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(studio.playback.skimImage == nil)
    }

    /// A paused scrub seeks the player to the exact frame.
    @Test("Moving the playhead while paused seeks the player")
    func scrubSeeksThePlayer() async throws {
        let (studio, folder) = try await ready()
        defer {
            studio.stopPlayback()
            try? FileManager.default.removeItem(at: folder)
        }
        for step in 1 ... 10 {
            studio.playhead = Double(step) * 0.1
            studio.playback.playheadDidChange(to: studio.playhead)
        }
        let player = try #require(studio.playback.player)
        let landed = try await StudioPlaybackFixtures.wait {
            abs(player.currentTime().seconds - 1) < 0.02
        }
        #expect(landed, "the player is at \(player.currentTime().seconds)s, not the last scrub target")
    }

    /// Closing the window must leave nothing decoding.
    @Test("Stopping releases the player and everything it held")
    func stopReleasesEverything() async throws {
        let (studio, folder) = try await ready()
        defer { try? FileManager.default.removeItem(at: folder) }
        studio.play()
        try await StudioPlaybackFixtures.wait { studio.playhead > 0 }

        studio.stopPlayback()
        #expect(!studio.isPlaying)
        #expect(studio.playback.player == nil)
        #expect(studio.playback.outputSize == nil)
        #expect(!studio.playback.isBuilding)
        #expect(!studio.isPreviewAudioPlaying)
    }

    /// A build that lands after the window closed must not bring a player back.
    @Test("A build finishing after stop installs nothing")
    func lateBuildInstallsNothing() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 1)
        studio.previewPlayback.update()
        studio.stopPlayback()
        try await Task.sleep(for: .milliseconds(300))
        #expect(studio.playback.player == nil)
        #expect(studio.playback.outputSize == nil)
    }
}
