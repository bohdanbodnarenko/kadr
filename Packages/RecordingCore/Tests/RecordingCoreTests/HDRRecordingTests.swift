import AVFoundation
import Foundation
import Shared
import Testing
@testable import RecordingCore

/// HDR recording presets (docs/04 §4.3, docs/06 M25).
///
/// The settings dictionary is the whole contract with AVFoundation here: a missing colour
/// tag produces a file that plays back with the wrong gamma, which looks like a bad
/// recording rather than a missing key.
@Suite("HDR recording")
struct HDRRecordingTests {
    @Test("A standard recording carries no HDR colour tags")
    func standardHasNoColourTags() {
        let options = RecordingOptions(dynamicRange: .standard)
        let settings = options.videoSettings(pixelWidth: 1920, pixelHeight: 1080)
        #expect(settings[AVVideoColorPropertiesKey] == nil)
        #expect(!options.recordsHDR)
    }

    @Test("HDR needs a codec that can carry ten bits")
    func hdrNeedsHEVC() {
        #expect(!RecordingOptions(codec: .h264, dynamicRange: .high).recordsHDR)
        #expect(RecordingOptions(codec: .hevc, dynamicRange: .high).recordsHDR == DynamicRange.isAvailable)
    }

    @Test("An HDR recording is tagged HLG, so it still plays on an SDR display")
    func hdrCarriesHLGTags() throws {
        try #require(DynamicRange.isAvailable, "this system cannot capture HDR")

        let options = RecordingOptions(codec: .hevc, dynamicRange: .high)
        let settings = options.videoSettings(pixelWidth: 1920, pixelHeight: 1080)
        let colour = try #require(settings[AVVideoColorPropertiesKey] as? [String: Any])

        #expect(colour[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(colour[AVVideoColorPrimariesKey] as? String == AVVideoColorPrimaries_ITU_R_2020)
        #expect(colour[AVVideoYCbCrMatrixKey] as? String == AVVideoYCbCrMatrix_ITU_R_2020)
    }

    @Test("An HDR recording asks for a ten-bit profile")
    func hdrAsksForMain10() throws {
        try #require(DynamicRange.isAvailable, "this system cannot capture HDR")

        let options = RecordingOptions(codec: .hevc, dynamicRange: .high)
        let settings = options.videoSettings(pixelWidth: 1920, pixelHeight: 1080)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoProfileLevelKey] != nil)
    }

    @Test("Everything else about the recording is unchanged by the range", arguments: [
        DynamicRange.standard, .high
    ])
    func otherSettingsAreUnchanged(range: DynamicRange) throws {
        let options = RecordingOptions(frameRate: .thirty, codec: .hevc, dynamicRange: range)
        let settings = options.videoSettings(pixelWidth: 1280, pixelHeight: 720)

        #expect(settings[AVVideoWidthKey] as? Int == 1280)
        #expect(settings[AVVideoHeightKey] as? Int == 720)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoExpectedSourceFrameRateKey] as? Int == 30)
        #expect(compression[AVVideoAverageBitRateKey] != nil)
    }

    @Test("Asking for HDR on a system that cannot do it records standard, not nothing")
    func degradesRatherThanFailing() {
        let options = RecordingOptions(codec: .hevc, dynamicRange: .high)
        #expect(options.dynamicRange == DynamicRange.high.resolved)
    }
}
