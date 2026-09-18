import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import StudioRender

/// Compressed export: a quality target instead of a bit-rate target (docs/09 U3.3).
@Suite("Studio compression")
struct StudioCompressionTests {
    private typealias Media = StudioMediaFixtures
    private let size = CGSize(width: 1280, height: 720)

    @Test("The encoder is asked for a quality or a bit rate, never both", arguments: [
        (AVVideoCodecType.hevc, Double?.none),
        (.hevc, 0.7),
        (.h264, nil),
        (.h264, 0.8)
    ])
    func compressionProperties(codec: AVVideoCodecType, quality: Double?) {
        let options = StudioRenderer.Options(codec: codec, frameRate: 30, targetQuality: quality)
        let properties = StudioRenderer.compressionProperties(for: options, size: size)
        if let quality {
            #expect(properties[AVVideoQualityKey] as? Double == quality)
            #expect(properties[AVVideoAverageBitRateKey] == nil)
            #expect(properties[AVVideoMaxKeyFrameIntervalKey] as? Int == 120)
        } else {
            #expect(properties[AVVideoQualityKey] == nil)
            #expect((properties[AVVideoAverageBitRateKey] as? Int ?? 0) > 0)
            #expect(properties[AVVideoMaxKeyFrameIntervalKey] as? Int == 60)
        }
        #expect((properties[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
            == (codec == .h264))
    }

    @Test("Quality is clamped, and audio can be given its own rate")
    func optionsNormalise() {
        #expect(StudioRenderer.Options(targetQuality: 4).targetQuality == 1)
        #expect(StudioRenderer.Options(targetQuality: -1).targetQuality == 0.05)
        #expect(StudioRenderer.Options().aacSettings[AVEncoderBitRateKey] as? Int == 128_000)
        #expect(StudioRenderer.Options(audioBitRate: 96000).aacSettings[AVEncoderBitRateKey] as? Int == 96000)
    }

    @Test("A compressed export is smaller and shows the same picture")
    func compressedIsSmallerAndFaithful() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 2, in: folder, size: size, textPage: true)
        let source = StudioRenderer.Source(screen: movie, edit: Media.edit(duration: 2), pixelSize: size)

        let plain = folder.appendingPathComponent("plain.mov")
        let compressed = folder.appendingPathComponent("compressed.mov")
        try await StudioRenderer().render(
            source,
            to: plain,
            options: .init(codec: .hevc, frameRate: 30, includeAudio: false)
        )
        let output = try await StudioRenderer().render(
            source,
            to: compressed,
            options: .init(codec: .hevc, frameRate: 30, includeAudio: false, targetQuality: 0.7)
        )

        func bytes(_ url: URL) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        }
        #expect(try bytes(compressed) < bytes(plain), "a still picture should cost less at a quality target")
        #expect(output.frameCount > 50)

        // Same picture: the mean per-byte difference between the two renders' frames is
        // what a viewer would call identical.
        let reference = try await Media.frameBytes(of: plain, limit: 30)
        let candidate = try await Media.frameBytes(of: compressed, limit: 30)
        let frame = min(reference.count, candidate.count) - 1
        #expect(frame > 0)
        #expect(Media.difference(reference[frame], candidate[frame]) < 3)
    }
}

@Suite("Plan output size")
struct PlanOutputSizeTests {
    @Test("The cheap size agrees with a full plan", arguments: [nil, 1920, 1280, 854] as [Int?])
    func matchesFullPlan(cap: Int?) {
        let edit = StudioMediaFixtures.edit(duration: 3)
        let source = CGSize(width: 3024, height: 1964)
        let full = StudioRenderPlan(edit: edit, sourceSize: source, maxLongestEdge: cap).outputSize
        #expect(StudioRenderPlan.outputSize(edit: edit, sourceSize: source, maxLongestEdge: cap) == full)
    }
}
