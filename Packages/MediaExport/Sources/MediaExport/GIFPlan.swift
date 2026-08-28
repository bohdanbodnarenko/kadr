import CoreGraphics
import Foundation

/// What a GIF encode will actually do, decided before it starts (docs/03 §1.8).
///
/// The reason this type exists is memory. `CGImageDestination` does not stream: every
/// frame added to a GIF destination is held until `finalize`, whatever order they arrive
/// in. So peak RAM is the *whole GIF's* decoded frames, not one of them — a minute of
/// 800-wide, 15 fps footage is around 1.3 GB, and a five-minute screen recording is enough
/// to have the encoder killed (docs/07 M10).
///
/// Rather than fail on long recordings, the encode is planned to fit a budget: frame rate
/// comes down first, then width, and only then is the clip cut short — in that order
/// because a slower, smaller GIF is still the whole recording, while a clipped one is not.
/// Whatever the plan decides is reported back, so the user is asked about the GIF they are
/// actually going to get.
public struct GIFPlan: Sendable, Hashable {
    /// The frame rate the encode will use, which may be below the one requested.
    public var frameRate: Int
    /// The longest edge the encode will use, which may be below the one requested.
    public var maximumWidth: Int
    /// How many seconds of the recording the GIF will cover.
    public var encodedSeconds: Double
    /// How long the recording is.
    public var sourceSeconds: Double
    public var frameCount: Int
    /// Roughly how much memory the encode will hold at its peak.
    public var estimatedPeakBytes: Int

    /// Whether the recording is longer than the GIF will be.
    public var isClipped: Bool {
        encodedSeconds + 0.01 < sourceSeconds
    }

    /// Whether the plan had to give up quality to fit the budget.
    public var isReduced: Bool {
        isClipped || frameRate < requestedFrameRate || maximumWidth < requestedWidth
    }

    /// What was asked for, kept so `isReduced` can mean something.
    public var requestedFrameRate: Int
    public var requestedWidth: Int

    public init(
        frameRate: Int,
        maximumWidth: Int,
        encodedSeconds: Double,
        sourceSeconds: Double,
        frameCount: Int,
        estimatedPeakBytes: Int,
        requestedFrameRate: Int,
        requestedWidth: Int
    ) {
        self.frameRate = frameRate
        self.maximumWidth = maximumWidth
        self.encodedSeconds = encodedSeconds
        self.sourceSeconds = sourceSeconds
        self.frameCount = frameCount
        self.estimatedPeakBytes = estimatedPeakBytes
        self.requestedFrameRate = requestedFrameRate
        self.requestedWidth = requestedWidth
    }

    /// Plans an encode of `sourceSeconds` of footage at `frameSize`, inside `budget` bytes.
    ///
    /// Pure arithmetic, so the ordering of the concessions is testable without encoding
    /// anything.
    public static func fitting(
        sourceSeconds: Double,
        frameSize: CGSize,
        options: GIFOptions
    ) -> GIFPlan {
        let duration = max(sourceSeconds, 0)
        let aspect = frameSize.width > 0 ? frameSize.height / frameSize.width : 0.5

        /// Bytes one decoded frame occupies at a given width.
        func frameBytes(width: Int) -> Double {
            let scaled = min(CGFloat(width), max(frameSize.width, 1))
            return Double(scaled * (scaled * aspect).rounded() * 4)
        }

        /// Frames a duration produces at a rate. Matches `frameTimes`' half-open stride.
        func frames(seconds: Double, rate: Int) -> Int {
            guard seconds > 0 else { return 0 }
            return max(1, Int((seconds * Double(rate)).rounded(.up)))
        }

        let budget = Double(options.peakMemoryBudget)

        /// Whether a plan of this shape fits the budget.
        func fits(seconds: Double, rate: Int, width: Int) -> Bool {
            Double(frames(seconds: seconds, rate: rate)) * frameBytes(width: width) <= budget
        }

        var rate = options.frameRate
        var width = min(options.maximumWidth, Int(max(frameSize.width, 1)))

        // 1. Slow it down, to the floor.
        while rate > Self.minimumFrameRate, !fits(seconds: duration, rate: rate, width: width) {
            rate -= 1
        }
        // 2. Shrink it, to the floor.
        while width > Self.minimumWidth, !fits(seconds: duration, rate: rate, width: width) {
            width = max(Self.minimumWidth, width - 40)
        }
        // 3. Only now, cut it short.
        var seconds = duration
        let perFrame = frameBytes(width: width)
        if perFrame > 0, !fits(seconds: seconds, rate: rate, width: width) {
            let affordable = max(1.0, (budget / perFrame).rounded(.down))
            seconds = min(duration, affordable / Double(rate))
        }

        let count = frames(seconds: seconds, rate: rate)
        return GIFPlan(
            frameRate: rate,
            maximumWidth: width,
            encodedSeconds: seconds,
            sourceSeconds: duration,
            frameCount: count,
            estimatedPeakBytes: Int(Double(count) * perFrame),
            requestedFrameRate: options.frameRate,
            requestedWidth: options.maximumWidth
        )
    }

    /// Below this a GIF stops reading as motion.
    static let minimumFrameRate = 8
    /// Below this the content stops being legible, which defeats the point of the export.
    static let minimumWidth = 320
}
