import Foundation
import Testing

/// For tests whose pass mark is a wall-clock budget from PRD §8 or docs/03.
///
/// They are judged on real Macs. CI's shared virtual machines have no Neural Engine, few
/// cores and main-thread stalls of seconds, so a timing measured there describes the
/// runner, not Kadr: the OCR budget, a pointer-sample cost and launch latency each failed
/// on CI while passing comfortably on hardware. `CI` reaches a hosted test through the
/// Makefile's `TEST_RUNNER_CI`. Budgets that do not depend on speed (memory, idle CPU, no
/// timers) are not marked and still run everywhere.
extension Trait where Self == ConditionTrait {
    static var judgedOnRealMacs: Self {
        .disabled(
            if: !(ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty,
            "a timing budget; judged on real Macs, not CI virtual machines"
        )
    }
}
