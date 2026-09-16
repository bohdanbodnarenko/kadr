import AVFoundation
import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// The preview's compositor, driven by AVFoundation itself (docs/09 U3.3).
///
/// Through a real `AVAssetImageGenerator` over a real composition, because what is worth
/// checking is that AVFoundation accepts the instruction, calls the compositor and gets a
/// frame of the planned size back — a mock would only confirm which methods exist.
@Suite("Studio video compositor")
struct StudioVideoCompositorTests {
    private func composition(seconds: Double, in folder: URL) async throws -> AVMutableComposition {
        let movie = try await StudioMediaFixtures.makeMovie(seconds: seconds, in: folder)
        return try await ClipCompositionBuilder().composition(
            for: StudioMediaFixtures.edit(duration: seconds).clips,
            screen: movie
        )
    }

    private func composer(edit: StudioEdit, sourceSize: CGSize, maxLongestEdge: Int?) -> StudioFrameComposer {
        let plan = StudioRenderPlan(edit: edit, sourceSize: sourceSize, maxLongestEdge: maxLongestEdge)
        return StudioFrameComposer(plan: plan, edit: edit, telemetry: InputTelemetry(), frameRate: 30)
    }

    @Test("A composed frame comes back at the plan's output size", arguments: [nil, 160] as [Int?])
    func framesComeBackAtThePlannedSize(maxLongestEdge: Int?) async throws {
        let folder = StudioMediaFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixed = try await composition(seconds: 1, in: folder)
        let edit = StudioMediaFixtures.edit(duration: 1)
        let composer = composer(
            edit: edit,
            sourceSize: CGSize(width: 320, height: 180),
            maxLongestEdge: maxLongestEdge
        )
        let video = try #require(StudioVideoComposition.make(
            for: mixed,
            composer: composer,
            frameRate: 30
        ))
        #expect(video.renderSize == composer.plan.outputSize)

        let generator = AVAssetImageGenerator(asset: mixed)
        generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 1, timescale: 2)).image
        #expect(CGFloat(image.width) == composer.plan.outputSize.width)
        #expect(CGFloat(image.height) == composer.plan.outputSize.height)
    }

    /// The picture is the recording's, not black: the fixture is red on the left and blue
    /// on the right, and an untouched edit shows both.
    @Test("The composed frame carries the recording's picture")
    func framesCarryThePicture() async throws {
        let folder = StudioMediaFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixed = try await composition(seconds: 1, in: folder)
        let edit = StudioMediaFixtures.edit(duration: 1)
        let composer = composer(edit: edit, sourceSize: CGSize(width: 320, height: 180), maxLongestEdge: nil)
        let generator = AVAssetImageGenerator(asset: mixed)
        generator.videoComposition = StudioVideoComposition.make(
            for: mixed,
            composer: composer,
            frameRate: 30
        )
        let image = try await generator.image(at: .zero).image

        let left = try #require(Self.pixel(of: image, x: image.width / 4, y: image.height / 2))
        let right = try #require(Self.pixel(of: image, x: image.width * 3 / 4, y: image.height / 2))
        #expect(left.red > 150 && left.blue < 100, "left half was \(left)")
        #expect(right.blue > 150 && right.red < 100, "right half was \(right)")
    }

    /// A generator given a `maximumSize` shrinks the render context, and a frame drawn at
    /// the planned size into that smaller buffer used to show only its corner.
    @Test("A shrunken render context still gets the whole frame")
    func shrunkenContextGetsTheWholeFrame() async throws {
        let folder = StudioMediaFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixed = try await composition(seconds: 1, in: folder)
        let edit = StudioMediaFixtures.edit(duration: 1)
        let composer = composer(edit: edit, sourceSize: CGSize(width: 320, height: 180), maxLongestEdge: nil)
        let generator = AVAssetImageGenerator(asset: mixed)
        generator.videoComposition = StudioVideoComposition.make(
            for: mixed,
            composer: composer,
            frameRate: 30
        )
        generator.maximumSize = CGSize(width: 80, height: 80)
        let image = try await generator.image(at: .zero).image
        #expect(image.width <= 80)

        let right = try #require(Self.pixel(of: image, x: image.width * 7 / 8, y: image.height / 2))
        #expect(right.blue > 150, "the right edge of a shrunken frame was \(right), not the recording")
    }

    @Test("No composition without a video track")
    func noVideoTrackNoComposition() {
        let edit = StudioMediaFixtures.edit(duration: 1)
        let composer = composer(edit: edit, sourceSize: CGSize(width: 320, height: 180), maxLongestEdge: nil)
        #expect(StudioVideoComposition.make(
            for: AVMutableComposition(),
            composer: composer,
            frameRate: 30
        ) == nil)
    }

    @Test("The instruction asks for the screen and, when there is one, the camera")
    func instructionNamesItsTracks() {
        let edit = StudioMediaFixtures.edit(duration: 1)
        let composer = composer(edit: edit, sourceSize: CGSize(width: 320, height: 180), maxLongestEdge: nil)
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        let screenOnly = StudioVideoCompositionInstruction(
            timeRange: range, composer: composer, screenTrackID: 1, cameraTrackID: nil
        )
        let withCamera = StudioVideoCompositionInstruction(
            timeRange: range, composer: composer, screenTrackID: 1, cameraTrackID: 2
        )
        #expect(screenOnly.requiredSourceTrackIDs?.compactMap { ($0 as? NSNumber)?.int32Value } == [1])
        #expect(withCamera.requiredSourceTrackIDs?.compactMap { ($0 as? NSNumber)?.int32Value } == [1, 2])
        #expect(withCamera.passthroughTrackID == kCMPersistentTrackID_Invalid)
    }

    private struct Pixel: CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var description: String {
            "rgb(\(red), \(green), \(blue))"
        }
    }

    /// One pixel, drawn into a known RGBA layout so the byte order is not a guess.
    private static func pixel(of image: CGImage, x: Int, y: Int) -> Pixel? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Top-left pixel coordinates into CoreGraphics' bottom-left space.
            context.draw(image, in: CGRect(
                x: -x,
                y: -(image.height - 1 - y),
                width: image.width,
                height: image.height
            ))
            return true
        }
        guard drawn else { return nil }
        return Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }
}
