import AVFoundation
import CoreImage
import Foundation

/// The pieces the staged export is built from (docs/09 U3.3, PRD §8).
///
/// The render used to be one loop doing four jobs strictly in turn: decode a frame, build
/// its recipe, wait for the GPU to draw it, hand it to the encoder. The decoder sat idle
/// while the GPU worked and the GPU sat idle while the decoder worked. Now each frame is
/// started on the GPU and left there while the loop decodes and composes the next one, and
/// only then is the first collected and written — the two overlap by a frame.
///
/// **Why one task, not a task per stage.** The obvious design — a decode task and a compose
/// task feeding bounded queues — was built and deadlocked. `copyNextSampleBuffer` blocks
/// its thread, and the reader stops decoding once enough of the frames it has handed out
/// are still held; those are released by the later stages, which are tasks needing a
/// thread from the same cooperative pool. Several exports at once (the test suite runs a
/// dozen) blocked every pool thread in a decoder, and nothing could ever run again. The overlap here keeps the one
/// blocking call and the code that releases its
/// buffers on the same task, so that cannot happen, and it still gets the one overlap that
/// matters — decoding while the GPU draws. The encoder already runs on AVFoundation's own
/// threads. No dispatch queue is involved (CLAUDE.md rule 5).
extension StudioRenderer {
    /// One frame that has been picked and decoded, ready to be composed.
    struct FrameJob {
        /// Index in the output's frame clock, for progress.
        let frame: Int
        let time: CMTime
        let seconds: TimeInterval
        let source: CIImage
        let camera: CIImage?
    }

    /// One frame on its way through the GPU: the buffer it is being drawn into, and the
    /// task to wait on before the buffer may be given to the encoder.
    struct RenderedJob {
        let frame: Int
        let time: CMTime
        let buffer: CVPixelBuffer
        let task: CIRenderTask
    }

    /// Reports progress no more often than every half a percent.
    ///
    /// Every caller hops to the main actor to show it, and a sixty-frames-a-second export
    /// hopping sixty times a second is main-actor work that nobody can see: the bar is a
    /// few hundred points wide. At most two hundred reports now reach the caller, plus the
    /// one that says it is finished — which is always delivered, exactly once.
    struct ProgressThrottle {
        static let step = 0.005

        private let report: (@Sendable (Double) -> Void)?
        private var last = -Double.infinity
        private var finished = false

        init(_ report: (@Sendable (Double) -> Void)?) {
            self.report = report
        }

        mutating func update(_ value: Double) {
            guard let report, !finished else { return }
            if value >= 1 {
                finished = true
                last = 1
                report(1)
            } else if value - last >= Self.step {
                last = value
                report(value)
            }
        }
    }
}

/// How many exports may be reading footage at once (docs/09 U3.3).
///
/// `copyNextSampleBuffer` blocks the thread it is called on, and in an async function that
/// thread belongs to the cooperative pool — one per core, shared by the whole process.
/// Starting a reader evidently needs a pool thread of its own as well: with every pool
/// thread already blocked inside a reader, no reader could get started, and every export,
/// every thumbnail and every other `AVAssetReader` in the process stopped for good. The test
/// suite, which runs a dozen exports side by side, found it.
///
/// Admitting only half as many exports as there are cores keeps the other half free for
/// whatever AVFoundation needs, without a dispatch queue (CLAUDE.md rule 5). Nobody exports
/// eight movies at once from the studio; the limit costs a real user nothing.
actor ExportGate {
    static let shared = ExportGate(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    /// For tests: how many are admitted and how many are waiting.
    var load: (running: Int, waiting: Int) {
        (running, waiting.count)
    }

    /// Waits for room. Every successful call must be matched by one `release()`, on every
    /// path out — callers do it with a `do`/`catch` rather than a `defer`, which cannot wait.
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the slot straight to the next in line, or gives it back.
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
