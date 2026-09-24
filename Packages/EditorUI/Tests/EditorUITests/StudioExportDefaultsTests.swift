import CoreGraphics
import Foundation
import MediaExport
import Testing
@testable import EditorUI

/// Export choices that make files which play, and GIFs that say what they will be
/// (docs/17 T-STU-7, T-STU-10).
@Suite("Studio export defaults")
struct StudioExportDefaultsTests {
    @Test("A new export is H.264, which plays everywhere an MP4 is promised to")
    func defaultCodecPlaysEverywhere() {
        #expect(StudioExportSettings().codec == .h264)
    }

    @Test("H.264 is clamped to what the encoder accepts; HEVC is not", arguments: [
        (StudioExportSettings.Codec.h264, StudioExportSettings.Resolution.original, 4096 as Int?),
        (.h264, .fullHD, 1920),
        (.hevc, .original, nil),
        (.hevc, .hd, 1280)
    ])
    func h264Clamp(codec: StudioExportSettings.Codec, resolution: StudioExportSettings.Resolution, edge: Int?) {
        let settings = StudioExportSettings(codec: codec, resolution: resolution, container: .mp4)
        #expect(settings.maxLongestEdge == edge)
        #expect(settings.rendererOptions.maxLongestEdge == edge)
    }

    @Test("GIF size and rate are GIF's own choices and reach the encoder")
    func gifPickers() {
        let settings = StudioExportSettings(container: .gif, gifWidth: .medium, gifFrameRate: .standard)
        #expect(settings.gifOptions.maximumWidth == 640)
        #expect(settings.gifOptions.frameRate == 10)
        #expect(settings.maxLongestEdge == 640)
        // The intermediate movie is rendered at the GIF's rate, not 60.
        #expect(settings.rendererOptions(manifestFrameRate: 60).frameRate == 10)
    }

    @Test("A long GIF's plan is described, including a clipped duration")
    func gifPlanIsShown() {
        let settings = StudioExportSettings(container: .gif)
        let short = settings.gifPlan(outputSize: CGSize(width: 800, height: 500), duration: 5)
        #expect(!short.isReduced)
        let long = settings.gifPlan(outputSize: CGSize(width: 800, height: 500), duration: 3600)
        #expect(long.isClipped)
        let text = StudioExportOptionsView.describe(long)
        #expect(text.contains("fps") && text.contains("px") && text.contains("first"))
    }

    @Test("GIF estimates grow with length")
    func gifEstimate() throws {
        let settings = StudioExportSettings(container: .gif)
        let size = CGSize(width: 800, height: 450)
        let ten = try #require(settings.estimatedBytes(outputSize: size, duration: 10, manifestFrameRate: 60))
        let twenty = try #require(settings.estimatedBytes(outputSize: size, duration: 20, manifestFrameRate: 60))
        #expect(twenty > ten)
    }

    @Test("Settings remembered before GIF pickers existed still load")
    func legacyGIFDecode() throws {
        let legacy = Data(
            #"{"quality":"High","codec":"HEVC","resolution":"Original","container":"GIF","includeAudio":true}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(StudioExportSettings.self, from: legacy)
        #expect(decoded.gifWidth == .large)
        #expect(decoded.gifFrameRate == .smooth)
        #expect(decoded.codec == .hevc)
    }
}
