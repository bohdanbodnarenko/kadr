import CoreGraphics
import Foundation
import StudioSession

/// A crop window that follows the pointer, then hands off to a zoom (docs/16 STU-C1).
///
/// Vertical and square exports used to freeze a static centre crop and divide zoom
/// magnification by that crop's inherent zoom, which made every cue disappear. This
/// camera keeps the crop's size and moves its origin so the subject stays inside.
public struct ReframeCamera: Sendable {
    public static let deadZoneFraction: CGFloat = 0.28
    public static let smoothing: TimeInterval = 0.45

    public let windowSize: CGSize
    public let sourceSize: CGSize
    private let origins: [CGPoint]
    private let step: TimeInterval

    public init(
        sourceSize: CGSize,
        windowSize: CGSize,
        duration: TimeInterval,
        pointer: [PointerSample],
        zooms: [ZoomCue],
        step: TimeInterval = 1.0 / 60
    ) {
        self.sourceSize = sourceSize
        self.windowSize = CGSize(
            width: min(windowSize.width, sourceSize.width),
            height: min(windowSize.height, sourceSize.height)
        )
        self.step = max(step, 1.0 / 120)
        let count = max(Int((max(duration, 0) / self.step).rounded(.up)), 1)
        var origin = Self.clampedOrigin(
            aiming: CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2),
            window: self.windowSize,
            source: sourceSize
        )
        var table: [CGPoint] = []
        table.reserveCapacity(count)
        let ordered = zooms.filter(\.isEnabled).sorted { $0.start < $1.start }
        for index in 0 ..< count {
            let time = Double(index) * self.step
            let pointerPoint = Self.pointer(at: time, in: pointer)
                ?? CGPoint(x: origin.x + self.windowSize.width / 2, y: origin.y + self.windowSize.height / 2)
            var aim = pointerPoint
            if let zoom = Self.zoom(at: time, in: ordered) {
                let progress = Self.handoff(at: time, cue: zoom)
                let zoomPoint = zoom.anchor.point(in: sourceSize)
                aim = CGPoint(
                    x: pointerPoint.x + (zoomPoint.x - pointerPoint.x) * progress,
                    y: pointerPoint.y + (zoomPoint.y - pointerPoint.y) * progress
                )
            }
            let target = Self.clampedOrigin(aiming: aim, window: self.windowSize, source: sourceSize)
            let alpha = 1 - exp(-self.step / Self.smoothing)
            let dead = Self.deadZoneFraction * min(self.windowSize.width, self.windowSize.height)
            let centre = CGPoint(
                x: origin.x + self.windowSize.width / 2,
                y: origin.y + self.windowSize.height / 2
            )
            if hypot(aim.x - centre.x, aim.y - centre.y) > dead {
                origin = CGPoint(
                    x: origin.x + (target.x - origin.x) * alpha,
                    y: origin.y + (target.y - origin.y) * alpha
                )
            }
            origin = Self.clampedOrigin(
                aiming: CGPoint(x: origin.x + self.windowSize.width / 2, y: origin.y + self.windowSize.height / 2),
                window: self.windowSize,
                source: sourceSize
            )
            table.append(origin)
        }
        origins = table
    }

    public func crop(at time: TimeInterval) -> CGRect {
        let origin = origins.isEmpty
            ? .zero
            : origins[min(max(Int((time / step).rounded()), 0), origins.count - 1)]
        return CGRect(origin: origin, size: windowSize)
    }

    static func clampedOrigin(aiming: CGPoint, window: CGSize, source: CGSize) -> CGPoint {
        let maxX = max(source.width - window.width, 0)
        let maxY = max(source.height - window.height, 0)
        return CGPoint(
            x: min(max(aiming.x - window.width / 2, 0), maxX),
            y: min(max(aiming.y - window.height / 2, 0), maxY)
        )
    }

    private static func pointer(at time: TimeInterval, in samples: [PointerSample]) -> CGPoint? {
        TimeSortedLookup.lastIndex(atOrBefore: time, in: samples, key: \.time)
            .map { samples[$0].position }
    }

    private static func zoom(at time: TimeInterval, in cues: [ZoomCue]) -> ZoomCue? {
        cues.last { time >= $0.start && time <= $0.end }
    }

    /// 0 while idle, 1 once the zoom is fully in.
    private static func handoff(at time: TimeInterval, cue: ZoomCue) -> Double {
        let ramp = max(cue.transitionDuration, 0.001)
        return min(max((time - cue.start) / ramp, 0), 1)
    }
}
