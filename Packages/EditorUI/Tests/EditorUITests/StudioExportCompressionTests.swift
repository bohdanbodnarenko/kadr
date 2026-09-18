import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// The Compress switch in the export options (docs/09 U3.3).
@Suite("Studio export compression")
struct StudioExportCompressionTests {
    @Test("Settings remembered before Compress existed still load")
    func legacySettingsDecode() throws {
        let legacy = Data(
            #"{"quality":"Medium","codec":"H.264","resolution":"720p","container":"MP4","includeAudio":false}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(StudioExportSettings.self, from: legacy)
        #expect(decoded.quality == .medium)
        #expect(decoded.codec == .h264)
        #expect(decoded.resolution == .hd)
        #expect(decoded.container == .mp4)
        #expect(decoded.includeAudio == false)
        #expect(decoded.frameRate == .source)
        #expect(decoded.compresses == false)
    }

    @Test("Compress round-trips")
    func roundTrip() throws {
        let settings = StudioExportSettings(quality: .low, compresses: true)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(StudioExportSettings.self, from: data) == settings)
    }

    @Test("Compress turns into a quality target and a lighter soundtrack", arguments: [
        (StudioExportSettings.Quality.high, 0.8),
        (.medium, 0.7),
        (.low, 0.6)
    ])
    func rendererOptions(quality: StudioExportSettings.Quality, target: Double) {
        let compressed = StudioExportSettings(quality: quality, compresses: true).rendererOptions
        #expect(compressed.targetQuality == target)
        #expect(compressed.audioBitRate == 96000)

        let plain = StudioExportSettings(quality: quality).rendererOptions
        #expect(plain.targetQuality == nil)
        #expect(plain.audioBitRate == nil)
    }

    @Test("A GIF ignores Compress: its movie is only an intermediate")
    func gifIgnoresCompression() {
        let settings = StudioExportSettings(container: .gif, compresses: true)
        #expect(!settings.usesCompression)
        #expect(settings.rendererOptions.targetQuality == nil)
        #expect(settings.estimatedBytes(
            outputSize: CGSize(width: 800, height: 450),
            duration: 10,
            manifestFrameRate: 30
        ) == nil)
    }

    @Test("The estimate follows the bit rate, the length and the quality")
    func estimate() throws {
        let size = CGSize(width: 1920, height: 1080)
        let high = try #require(StudioExportSettings(quality: .high)
            .estimatedBytes(outputSize: size, duration: 10, manifestFrameRate: 60))
        let low = try #require(StudioExportSettings(quality: .low)
            .estimatedBytes(outputSize: size, duration: 10, manifestFrameRate: 60))
        let longer = try #require(StudioExportSettings(quality: .high)
            .estimatedBytes(outputSize: size, duration: 20, manifestFrameRate: 60))
        #expect(low < high)
        #expect(longer == high * 2 || abs(longer - high * 2) <= 1)
        // 1080p60 at 0.1 bits per pixel per frame is about 12.4 Mb/s, plus 128 kb/s of AAC.
        #expect(abs(high - 15_712_500) < 50000)
    }
}
