import CoreMedia
import Foundation
import Shared

/// Test seams; Debug-only, so none of this exists in a shipped build.
extension RecordingEngine {
    #if DEBUG
        /// Puts the engine into the state a running recording leaves it in.
        ///
        /// A test seam, and a deliberate one: everything upstream of `stop` needs
        /// ScreenCaptureKit and a real display, which CI has neither of — but the state
        /// machine `stop` drives is exactly where the review found a recording could brick
        /// (docs/07 C3). Debug-only, so it cannot exist in a shipped build.
        func primeForTesting(
            state: RecordingState,
            segments: [URL],
            sessionDirectory: URL?,
            writer: (any SegmentWriting)? = nil
        ) {
            self.state = state
            self.segments = segments
            self.sessionDirectory = sessionDirectory
            self.writer = writer
            accumulatedDuration = writer == nil ? 1 : 0
            pixelSize = PixelSize(width: 100, height: 100)
        }

        /// What `start` claims before its first suspension.
        func beginStartForTesting() -> Int {
            state = .starting
            return beginGeneration()
        }

        /// What `start` does when it resumes from that suspension.
        ///
        /// `start` itself cannot run in CI — it needs a display and a TCC grant — but the
        /// race S0.3 closes is entirely about what happens on the way *back*, so this is
        /// the resumption with the same generation check the real one performs.
        func finishStartForTesting(token: Int) throws {
            try checkAlive(token)
            state = .recording
            beginActivity()
        }

        /// Yields a stream-stopped event the way `SCStreamDelegate` would (docs/16 REC-1).
        func deliverStreamStopForTesting(_ message: String) {
            noteInterruption(.streamStopped(message))
            output?.finish()
        }

        /// Hands a sample to the engine as the stream's consumer would.
        func deliverForTesting(_ box: SampleBufferBox) async {
            await consume(box)
        }

        func deliverWriterFailureForTesting(_ message: String) {
            noteInterruption(.writerFailed(message))
        }

        var accumulatedDurationForTesting: TimeInterval {
            accumulatedDuration
        }

        var segmentsForTesting: [URL] {
            segments
        }

        /// When the frame a resume would open on was captured.
        var heldFrameTimeForTesting: CMTime? {
            lastVideoBox.map { CMSampleBufferGetPresentationTimeStamp($0.buffer) }
        }
    #endif
}
