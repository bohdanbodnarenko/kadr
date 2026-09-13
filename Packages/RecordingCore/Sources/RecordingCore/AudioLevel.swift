import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Instantaneous recording loudness, as a fraction of full scale (CleanShot §13.3).
///
/// Fed from the same sample buffers the writer sees, so the meter is the recording rather
/// than a second tap that could disagree with it. Updated only while a recording is
/// running — idle has nothing to sample.
public struct AudioMeter: Sendable, Hashable {
    /// Below this, a microphone that is supposed to be on is treated as muted.
    public static let silence: Float = 0.02

    public var microphone: Float
    public var system: Float

    public init(microphone: Float = 0, system: Float = 0) {
        self.microphone = Self.clamped(microphone)
        self.system = Self.clamped(system)
    }

    public var microphoneIsSilent: Bool { microphone < Self.silence }

    public var peak: Float { max(microphone, system) }

    static func clamped(_ value: Float) -> Float {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

/// Peak sample of a buffer, 0…1 (CleanShot §13.3).
public enum AudioLevel {
    /// Peak of already-decoded samples.
    public static func peak(of samples: [Float]) -> Float {
        var loudest: Float = 0
        for sample in samples {
            loudest = max(loudest, abs(sample))
        }
        return AudioMeter.clamped(loudest)
    }

    /// Peak of a ScreenCaptureKit audio buffer. Unknown layouts read as silence rather
    /// than crashing the recording.
    public static func peak(of buffer: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM
        else {
            return 0
        }

        var byteCount = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: &byteCount,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr || sizeStatus == kCMSampleBufferError_ArrayTooSmall, byteCount > 0 else {
            return 0
        }

        let alignment = MemoryLayout<AudioBufferList>.alignment
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: byteCount,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return 0 }

        var loudest: Float = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(list) {
            loudest = max(loudest, peak(of: audioBuffer, asbd: asbd))
        }
        return AudioMeter.clamped(loudest)
    }

    private static func peak(of audioBuffer: AudioBuffer, asbd: AudioStreamBasicDescription) -> Float {
        guard let data = audioBuffer.mData else { return 0 }
        let bytes = Int(audioBuffer.mDataByteSize)
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
            let count = bytes / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            var loudest: Float = 0
            for sample in samples {
                loudest = max(loudest, abs(sample))
            }
            return loudest
        }
        if asbd.mBitsPerChannel == 16 {
            let count = bytes / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
            var loudest: Float = 0
            for sample in samples {
                loudest = max(loudest, abs(Float(sample) / Float(Int16.max)))
            }
            return loudest
        }
        return 0
    }
}
