import AVFoundation
import Foundation
import MediaExport
import StudioRender
import Testing
import UniformTypeIdentifiers
@testable import EditorUI

@Suite("Studio filmstrip")
struct StudioFilmstripTests {
    @Test("Sample times are midpoints of equal slices")
    func sampleTimesAreMidpoints() {
        let times = StudioFilmstrip.sampleTimes(start: 10, duration: 4, count: 4)
        #expect(times == [10.5, 11.5, 12.5, 13.5])
    }

    @Test("A single tile samples the middle of the clip")
    func oneTileIsTheMiddle() {
        #expect(StudioFilmstrip.sampleTimes(start: 0, duration: 2, count: 1) == [1])
    }

    @Test("Zero duration or zero count yields no times")
    func emptyInputs() {
        #expect(StudioFilmstrip.sampleTimes(start: 0, duration: 0, count: 4).isEmpty)
        #expect(StudioFilmstrip.sampleTimes(start: 0, duration: 2, count: 0).isEmpty)
    }

    @Test("A missing file yields no frames rather than throwing")
    func missingFile() async {
        let url = URL(fileURLWithPath: "/tmp/kadr-no-such-recording.mov")
        let images = await StudioFilmstrip.images(from: url, times: [0, 0.5, 1])
        #expect(images.isEmpty)
    }

    @Test("Tile count is at least one and grows with width")
    func tileCount() {
        #expect(StudioFilmstrip.tileCount(forWidth: 10) == 1)
        #expect(StudioFilmstrip.tileCount(forWidth: 108) == 3)
    }
}

@Suite("Studio export settings")
struct StudioExportSettingsTests {
    @Test("1080p caps the long edge at 1920")
    func fullHDIsNineteenTwenty() {
        var settings = StudioExportSettings()
        settings.resolution = .fullHD
        #expect(settings.maxLongestEdge == 1920)
        #expect(settings.rendererOptions.maxLongestEdge == 1920)
    }

    @Test("MP4 is a different container than MOV")
    func mp4Container() {
        var settings = StudioExportSettings()
        settings.container = .mp4
        #expect(settings.filenameExtension == "mp4")
        #expect(settings.rendererOptions.fileType == .mp4)
        #expect(settings.utType == .mpeg4Movie)
    }

    @Test("Low quality lowers the bit-rate multiplier")
    func qualityScalesBitRate() {
        var settings = StudioExportSettings()
        settings.quality = .low
        #expect(settings.rendererOptions.bitRateMultiplier == 0.3)
        settings.quality = .high
        #expect(settings.rendererOptions.bitRateMultiplier == 1)
    }

    @Test("Audio can be left out of the encode")
    func droppingAudio() {
        var settings = StudioExportSettings()
        settings.includeAudio = false
        #expect(!settings.rendererOptions.includeAudio)
    }

    @Test("H.264 is the compatibility codec")
    func h264() {
        var settings = StudioExportSettings()
        settings.codec = .h264
        #expect(settings.rendererOptions.codec == .h264)
    }

    @Test("GIF is an animated image, not a movie")
    func gifContainer() {
        var settings = StudioExportSettings()
        settings.container = .gif
        settings.includeAudio = true
        settings.quality = .high
        #expect(settings.filenameExtension == "gif")
        #expect(settings.utType == .gif)
        #expect(!settings.rendererOptions.includeAudio)
        #expect(settings.rendererOptions.fileType == .mov)
        #expect(settings.rendererOptions.codec == .h264)
        #expect(settings.maxLongestEdge == 800)
        #expect(settings.gifOptions.frameRate == 15)
    }

    @Test("A smaller GIF uses the chosen resolution cap")
    func gifResolutionCap() {
        var settings = StudioExportSettings()
        settings.container = .gif
        settings.resolution = .sd
        settings.quality = .low
        #expect(settings.gifOptions.maximumWidth == 480)
        #expect(settings.gifOptions.frameRate == 8)
    }
}
