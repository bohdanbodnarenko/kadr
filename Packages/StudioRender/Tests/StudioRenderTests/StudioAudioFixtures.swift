import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import StudioRender

extension StudioMediaFixtures {
    /// A movie with a picture and a tone: `seconds` of 30 fps video and `audioSeconds` of
    /// 48 kHz stereo PCM. The two can differ, because a real recording's audio often runs a
    /// little past its last frame — and a render that only ever sees matched lengths never
    /// meets the audio left over.
    static func makeMovieWithAudio(
        seconds: Double,
        audioSeconds: Double,
        in folder: URL,
        named name: String = "screen.mov",
        size: CGSize = CGSize(width: 320, height: 180)
    ) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let picture = try solidPicture(size: size)

        // Whichever input is asking gets fed. The writer interleaves the two, so it will
        // stop taking picture until enough sound has arrived and the other way round: a
        // loop that waits on one input while the other is the one asking never finishes.
        var nextVideo = 0
        var nextAudio = 0
        let videoFrames = Int((seconds * 30).rounded())
        let audioFrames = Int((audioSeconds * 30).rounded())
        while nextVideo < videoFrames || nextAudio < audioFrames {
            var fed = false
            if nextVideo < videoFrames, video.isReadyForMoreMediaData {
                appendFrame(nextVideo, of: picture, to: adaptor)
                nextVideo += 1
                if nextVideo == videoFrames {
                    video.markAsFinished()
                }
                fed = true
            }
            if nextAudio < audioFrames, audio.isReadyForMoreMediaData {
                if let sample = toneSample(startingAt: Double(nextAudio) / 30, seconds: 1.0 / 30) {
                    audio.append(sample)
                }
                nextAudio += 1
                if nextAudio == audioFrames {
                    audio.markAsFinished()
                }
                fed = true
            }
            if writer.status == .failed {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            if !fed {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        await writer.finishWriting()
        return url
    }

    private static func solidPicture(size: CGSize) throws -> CIImage {
        try CIImage(cgImage: #require(
            BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
                context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
                context.fill(CGRect(origin: .zero, size: size))
            }
        ))
    }

    private static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func appendFrame(
        _ frame: Int,
        of picture: CIImage,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) {
        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        StudioRenderContext.shared.render(picture, to: buffer, bounds: picture.extent, colorSpace: nil)
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }

    /// `seconds` of a 440 Hz tone as one PCM sample buffer, stamped at `start`.
    private static func toneSample(startingAt start: Double, seconds: Double) -> CMSampleBuffer? {
        let rate = 48000
        let frames = Int((seconds * Double(rate)).rounded())
        guard frames > 0, let format = pcmFormat(rate: rate) else { return nil }

        var samples = [Int16](repeating: 0, count: frames * 2)
        let offset = Int((start * Double(rate)).rounded())
        for index in 0 ..< frames {
            let value = Int16(sin(Double(offset + index) * 2 * .pi * 440 / Double(rate)) * 8000)
            samples[index * 2] = value
            samples[index * 2 + 1] = value
        }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let filled = samples.withUnsafeBytes { bytes in
            bytes.baseAddress.map {
                CMBlockBufferReplaceDataBytes(
                    with: $0,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                )
            }
        }
        guard filled == noErr else { return nil }

        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: CMTimeScale(rate)),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// Interleaved 16-bit stereo linear PCM.
    private static func pcmFormat(rate: Int) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return format
    }
}
