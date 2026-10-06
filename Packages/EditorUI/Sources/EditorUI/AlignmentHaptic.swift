import AppKit

/// Alignment haptic for timeline and crop snapping (docs/14 D4). One bump per new target.
@MainActor
enum AlignmentHaptic {
    private static var lastIdentity: String?

    static func snap(id: String) {
        guard lastIdentity != id else { return }
        lastIdentity = id
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func released() {
        lastIdentity = nil
    }
}

/// Snaps a time to nearby clip, zoom, playhead, or recording-edge times.
enum TimelineSnap {
    static let hitPoints: CGFloat = 8

    /// - Parameter bypassed: ⌘ held, which places the edge exactly where the pointer is
    ///   (docs/18 T-STU-12) — the same escape the annotation editor's guides use.
    static func snap(
        _ time: TimeInterval,
        candidates: [TimeInterval],
        scale: CGFloat,
        bypassed: Bool = false
    ) -> TimeInterval {
        guard !bypassed else { return time }
        let window = TimeInterval(hitPoints / max(scale, 0.001))
        guard let nearest = candidates.min(by: { abs($0 - time) < abs($1 - time) }) else {
            return time
        }
        if abs(nearest - time) <= window {
            return nearest
        }
        return time
    }
}
