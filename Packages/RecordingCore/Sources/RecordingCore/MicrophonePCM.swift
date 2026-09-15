import AVFoundation
import CoreMedia
import Foundation

/// Converts a ScreenCaptureKit microphone buffer to 16 kHz Int16 PCM (docs/16 REC-19d).
///
/// The teleprompter helper asks for that layout. Conversion happens off SCK's queue, in
/// the consumer, so a slow downsample cannot stall the recording.
public enum MicrophonePCM {
    public static func int16kHzMono(from buffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(buffer) else {
            return nil
        }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            return nil
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        guard let input = pcmBuffer(from: buffer, format: inputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let source = PCMOnce(input)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if source.consumed {
                status.pointee = .noDataNow
                return nil
            }
            source.consumed = true
            status.pointee = .haveData
            return source.buffer
        }
        guard error == nil, converted.frameLength > 0, let channel = converted.int16ChannelData?[0] else {
            return nil
        }
        return Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        ) == noErr else {
            return nil
        }
        return buffer
    }
}

private final nonisolated class PCMOnce: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
