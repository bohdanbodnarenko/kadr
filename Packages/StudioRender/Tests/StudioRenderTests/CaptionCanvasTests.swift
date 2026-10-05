import CoreGraphics
import Foundation
import Shared
import StudioSession
import Testing
@testable import StudioRender

@Suite("Caption karaoke")
struct CaptionCanvasTests {
    @Test("Karaoke paints the spoken word gold")
    func karaokeHighlightsTheActiveWord() throws {
        let highlighted = try #require(CaptionCanvas.image(
            text: "Hello world",
            fontSize: 28,
            opacity: 1,
            activeIndex: 0,
            spokenCount: 0
        ))
        let plain = try #require(CaptionCanvas.image(text: "Hello world", fontSize: 28, opacity: 1))
        #expect(goldPixels(in: highlighted) > 0, "the live word stayed white")
        #expect(goldPixels(in: plain) == 0, "plain captions picked up the karaoke color")
    }

    @Test("Burned-in captions follow the transcript and karaoke can be switched off")
    func speechCaptionKaraokeHonoursTheToggle() throws {
        var styled = StudioEdit.untouched(duration: 4)
        styled.showsCaptions = true
        let transcript = Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.4),
            TranscriptWord(text: "world", start: 0.5, end: 1.0)
        ])
        let size = CGSize(width: 400, height: 200)
        let on = try #require(
            StudioFrameComposer(
                plan: StudioRenderPlan(edit: styled, sourceSize: size),
                edit: styled,
                telemetry: InputTelemetry(),
                transcript: transcript
            ).speechCaption(at: 0.2)?.image
        )
        styled.highlightsSpokenWord = false
        let off = try #require(
            StudioFrameComposer(
                plan: StudioRenderPlan(edit: styled, sourceSize: size),
                edit: styled,
                telemetry: InputTelemetry(),
                transcript: transcript
            ).speechCaption(at: 0.2)?.image
        )
        #expect(goldPixels(in: on) > 0)
        #expect(goldPixels(in: off) == 0)
    }

    @Test("A light caption pill is brighter than a dark one")
    func lightThemeIsBrighter() throws {
        let dark = try #require(CaptionCanvas.image(
            text: "⌘⇧4",
            fontSize: 28,
            opacity: 1,
            appearance: .dark
        ))
        let light = try #require(CaptionCanvas.image(
            text: "⌘⇧4",
            fontSize: 28,
            opacity: 1,
            appearance: .light
        ))
        #expect(meanLuma(in: light) > meanLuma(in: dark))
    }

    /// Gold is high red and green, low blue — white text and the dark pill are not.
    private func goldPixels(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] > 180, pixels[index + 1] > 140, pixels[index + 2] < 120 {
                count += 1
            }
        }
        return count
    }

    private func meanLuma(in image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
        }
        return Double(total) / Double(width * height)
    }
}
