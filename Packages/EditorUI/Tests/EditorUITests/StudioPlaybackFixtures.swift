import AVFoundation
import CoreImage
import Foundation
import StudioRender
import StudioSession
import Testing
@testable import EditorUI

/// Real, tiny recordings for the tests that need a player to actually play.
///
/// The transport used to run on a sleeping task and would "play" a file containing the word
/// "footage". It runs on `AVPlayer` now, which is the point — so a test that wants the
/// playhead to move has to hand it something AVFoundation can decode.
@MainActor
enum StudioPlaybackFixtures {
    static let movieSize = CGSize(width: 160, height: 90)

    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-player-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A studio model over a real 30 fps movie of `seconds`.
    static func model(in folder: URL, seconds: Double) async throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try await writeMovie(seconds: seconds, to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: movieSize,
            frameRate: 30,
            duration: seconds,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @discardableResult
    static func wait(
        upTo timeout: Duration = .seconds(5),
        until condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func writeMovie(seconds: Double, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(movieSize.width),
            AVVideoHeightKey: Int(movieSize.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(movieSize.width),
                kCVPixelBufferHeightKey as String: Int(movieSize.height)
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let picture = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(origin: .zero, size: movieSize))
        for frame in 0 ..< Int((seconds * 30).rounded()) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            StudioRenderContext.shared.render(picture, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
