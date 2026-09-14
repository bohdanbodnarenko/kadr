import AppKit

/// Alignment haptic for snapping only (docs/14 D4). Rising-edge: one bump per new target.
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
