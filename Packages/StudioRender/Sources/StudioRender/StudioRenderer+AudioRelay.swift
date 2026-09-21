import AVFoundation
import Foundation

extension StudioRenderer {
    /// Carries the recording's sound from the reader to the writer, a buffer at a time.
    ///
    /// The writer interleaves picture and sound into one file, so it will not take more of
    /// either until the other has caught up: a video input that is not ready is very often
    /// one waiting for *sound*, and the way out is to give it some. A loop that waits for
    /// the picture input and only then reads sound waits for something that cannot happen —
    /// which is what an export of any recording with audio in it did, from the first second
    /// of footage onwards, and never finished.
    ///
    /// So sound is fed from every place the render waits, not just after each frame, and the
    /// input is marked finished the moment the reader has no more to give. Left open, a
    /// recording whose sound ends before its picture — muted in the middle, a mic that was
    /// unplugged — has the writer waiting for sound that will never come.
    final class AudioRelay {
        let input: AVAssetWriterInput
        private var output: AVAssetReaderAudioMixOutput?
        private(set) var isFinished = false

        init(input: AVAssetWriterInput) {
            self.input = input
        }

        /// Joins the reader's side, once there is one. With nothing to read, the input is
        /// finished straight away rather than left for the writer to wait on.
        func attach(_ output: AVAssetReaderAudioMixOutput?) {
            self.output = output
            if output == nil {
                finish()
            }
        }

        /// Moves one buffer across if the writer will take it, and says when it started.
        ///
        /// Nil means nothing moved: the writer is not asking for sound, or there is no more.
        /// `isFinished` tells those apart.
        func feed() -> TimeInterval? {
            guard !isFinished, let output, input.isReadyForMoreMediaData else { return nil }
            guard let sample = output.copyNextSampleBuffer() else {
                finish()
                return nil
            }
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            return input.append(sample) ? start : nil
        }

        /// Tells the writer no more sound is coming. Safe to call twice, which AVFoundation is
        /// not.
        func finish() {
            guard !isFinished else { return }
            isFinished = true
            input.markAsFinished()
        }
    }

    /// Copies audio through until it has caught up with the video.
    ///
    /// Never waits for the sound input: if the writer is not asking for sound it is asking
    /// for picture, and the wait for that feeds sound whenever it is wanted. Only once the
    /// picture is finished (`time` is infinite) is there nothing else to wait for.
    func drainAudio(upTo time: CMTime, writer: WriterBundle) async throws {
        guard let relay = writer.audio else { return }
        let limit = time == .positiveInfinity ? Double.infinity : CMTimeGetSeconds(time)
        var pause = Self.readyPollInitial
        while !relay.isFinished {
            try Task.checkCancellation()
            if let start = relay.feed() {
                if start >= limit {
                    return
                }
                pause = Self.readyPollInitial
                continue
            }
            if relay.isFinished || limit.isFinite {
                return
            }
            try failIfWriterFailed(writer)
            try await Task.sleep(nanoseconds: pause)
            pause = min(pause * 2, Self.readyPollLimit)
        }
    }

    /// Waits for the picture input to want more data, feeding the sound input while it does.
    ///
    /// A poll rather than `requestMediaDataWhenReady(on:using:)`, which would mean a
    /// dispatch queue and a continuation to hand each frame back to the render — for a
    /// flag that is almost always already true by the time the next frame is composed
    /// (CLAUDE.md rule 5).
    ///
    /// The sound is what makes this more than a poll. The writer holds back picture until it
    /// has the sound that goes with it, so the input can stay not-ready for as long as the
    /// sound is not supplied — and the one thing that supplies it is this loop.
    ///
    /// The sleep is what stops the rare stall from becoming a spin, and it backs off: a
    /// stall that clears within a millisecond — the encoder finishing one frame — costs
    /// half of one, and one that does not settles at ten milliseconds between looks rather
    /// than a thousand wake-ups a second. A failed writer never becomes ready again, so it
    /// is looked for on every pass rather than waited out.
    func waitUntilReady(_ writer: WriterBundle) async throws {
        var pause = Self.readyPollInitial
        while !writer.video.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try failIfWriterFailed(writer)
            if writer.audio?.feed() != nil {
                pause = Self.readyPollInitial
                continue
            }
            try await Task.sleep(nanoseconds: pause)
            pause = min(pause * 2, Self.readyPollLimit)
        }
    }

    func failIfWriterFailed(_ writer: WriterBundle) throws {
        if writer.writer.status == .failed {
            throw RenderError.writingFailed(writer.writer.error?.localizedDescription ?? "unknown")
        }
    }

    static let readyPollInitial: UInt64 = 500_000
    static let readyPollLimit: UInt64 = 10_000_000
}
