import AVFoundation
import CoreGraphics
import Shared
import Testing
@testable import RecordingCore

@Suite("Recording options")
struct RecordingOptionsTests {
    @Test("Defaults match doc 03 §1.8: 60 fps HEVC with system audio")
    func defaults() {
        let options = RecordingOptions()
        #expect(options.frameRate == .sixty)
        #expect(options.codec == .hevc)
        #expect(options.capturesSystemAudio)
        #expect(options.excludesOwnAudio, "Kadr's own sound must never land in a recording")
    }

    @Test("Video settings carry the codec and size AVFoundation needs")
    func videoSettings() {
        let settings = RecordingOptions(codec: .h264).videoSettings(pixelWidth: 1920, pixelHeight: 1080)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(settings[AVVideoWidthKey] as? Int == 1920)
        #expect(settings[AVVideoHeightKey] as? Int == 1080)
    }

    @Test("HEVC asks for a lower bit rate than H.264 at the same size")
    func hevcIsCheaper() {
        let hevc = RecordingOptions(codec: .hevc).bitRate(forPixelWidth: 1920, height: 1080)
        let h264 = RecordingOptions(codec: .h264).bitRate(forPixelWidth: 1920, height: 1080)
        #expect(hevc < h264)
    }

    @Test("Bit rate scales with pixels and frame rate")
    func bitRateScales() {
        let small = RecordingOptions(frameRate: .thirty).bitRate(forPixelWidth: 1280, height: 720)
        let large = RecordingOptions(frameRate: .thirty).bitRate(forPixelWidth: 2560, height: 1440)
        let faster = RecordingOptions(frameRate: .sixty).bitRate(forPixelWidth: 1280, height: 720)

        #expect(large > small)
        #expect(faster > small)
    }

    @Test("1080p60 asks for a bit rate that keeps screen text readable")
    func screenContentBitRate() {
        // Screen recordings are mostly static then suddenly change wholesale; text that
        // turns to mush on a scroll is the failure people notice.
        let bitRate = RecordingOptions().bitRate(forPixelWidth: 1920, height: 1080)
        #expect(bitRate > 8_000_000, "1080p60 at \(bitRate / 1_000_000) Mbps will smear on scroll")
        #expect(bitRate < 40_000_000, "\(bitRate / 1_000_000) Mbps is wasteful for screen content")
    }

    @Test("Audio is stereo AAC at 48 kHz")
    func audioSettings() {
        let settings = RecordingOptions().audioSettings()
        #expect(settings[AVSampleRateKey] as? Int == 48000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 2)
    }

    @Test("Mono mixdown is one AAC channel")
    func monoAudioSettings() {
        let settings = RecordingOptions(recordsMono: true).audioSettings()
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect((settings[AVEncoderBitRateKey] as? Int ?? 0) < 128_000)
    }

    @Test("Every frame rate the UI offers is a real one", arguments: RecordingFrameRate.allCases)
    func frameRates(rate: RecordingFrameRate) {
        #expect([24, 30, 60].contains(rate.rawValue))
        #expect(rate.title.contains("fps"))
    }

    @Test("Both codecs map to something AVFoundation understands", arguments: RecordingCodec.allCases)
    func codecs(codec: RecordingCodec) {
        #expect([AVVideoCodecType.hevc, .h264].contains(codec.avCodec))
    }
}

@Suite("Recording targets")
struct RecordingTargetTests {
    @Test("Targets are values, so they can be compared and stored")
    func equatable() {
        #expect(RecordingTarget.display(1) == .display(1))
        #expect(RecordingTarget.display(1) != .display(2))
        #expect(RecordingTarget.window(5) != .display(5))

        let region = DisplayRect(x: 0, y: 0, width: 100, height: 100)
        #expect(RecordingTarget.region(region, display: 1) == .region(region, display: 1))
    }
}
