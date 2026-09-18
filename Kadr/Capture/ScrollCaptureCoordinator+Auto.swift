import AppKit
import CaptureCore
import os
import SettingsKit
import Shared

/// The auto tier of scrolling capture: Kadr does the scrolling (docs/03 §1.6, docs/04 §4.4).
///
/// Split from the coordinator so the file that drives both tiers stays readable, and
/// because this half is the one with a permission, a loop and a stopping rule to explain.
@MainActor
extension ScrollCaptureCoordinator {
    // MARK: - The auto tier

    /// Whether Kadr can take over the scrolling right now.
    var canAutoScroll: Bool {
        state == .capturing && !isAutoScrolling && region != nil
    }

    /// Takes over the scrolling, from the HUD's button or from the setting.
    ///
    /// Safe to call when it is already running, or before there is a region: the button is
    /// live while the capture is, and the user pressing it twice is not an error.
    func beginAutoScroll() {
        guard let region, canAutoScroll else { return }
        startAutoScroll(in: region.rect, on: region.display)
    }

    /// Hands the scrolling back to the user without ending the capture.
    func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        isAutoScrolling = false
    }

    /// Scrolls the target itself, stopping when the page stops changing (docs/04 §4.4).
    func startAutoScroll(in rect: DisplayRect, on display: DisplayGeometry) {
        guard AutoScroller.isTrusted else {
            // Asking now rather than at launch is the whole policy (docs/04 §3.2). The
            // grant only takes effect next time, so this run stays assisted.
            AutoScroller.requestTrust()
            explainAccessibility()
            return
        }

        isAutoScrolling = true
        let centre = centrePoint(of: rect, on: display)
        let axis = settings.scrollAxis
        let configuration = AutoScroller.Configuration(pointsPerStep: settings.scrollStepPoints)
        // Along the axis being scrolled: a step is capped against the frame it has to
        // overlap, not against a number from Settings that knows nothing about this region.
        let extent = axis == .vertical ? rect.height : rect.width
        let step = AutoScrollPlan.stepPoints(
            requested: configuration.pointsPerStep,
            regionPoints: Int(extent.rounded())
        )
        logger.info("Auto-scroll stepping \(step, privacy: .public) pt of \(Int(extent), privacy: .public)")

        autoScrollTask = Task { [weak self] in
            guard let self else { return }
            var detector = ScrollSettleDetector(axis: axis)
            for _ in 0 ..< configuration.maximumSteps {
                if Task.isCancelled {
                    return
                }
                let sequenceBefore = frameSequence
                await scroller.glide(at: centre, step: step, axis: axis)
                guard await waitForFrame(after: sequenceBefore, within: configuration) else {
                    // No frame at all: the stream has stopped, or the capture is ending.
                    break
                }
                if settled(&detector, axis: axis) {
                    logger.info("Auto-scroll settled; the page has run out")
                    break
                }
            }
            guard !Task.isCancelled else { return }
            isAutoScrolling = false
            stop()
        }
    }

    /// Waits for a frame newer than `sequence`, so "settled" is a judgement about the page
    /// rather than about a frame that has not arrived yet.
    ///
    /// The old loop slept a fixed time and then read whatever profile it had. On a slow
    /// frame the profile was the *same one* it had judged last time, which reads as no
    /// movement — two of those in a row and auto-scroll stopped in the middle of a page.
    private func waitForFrame(
        after sequence: Int,
        within configuration: AutoScroller.Configuration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(configuration.settleMilliseconds * 4))
        // A settle wait first: the page is still moving right after a glide, and the frame
        // that matters is the one taken once it has stopped.
        try? await Task.sleep(for: .milliseconds(configuration.settleMilliseconds))
        while frameSequence == sequence {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                return frameSequence != sequence
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return true
    }

    private func settled(_ detector: inout ScrollSettleDetector, axis: ScrollAxis) -> Bool {
        switch axis {
        case .vertical:
            guard let profile = lastRowProfile else { return false }
            return detector.settled(with: profile)
        case .horizontal:
            guard let profile = lastColumnProfile else { return false }
            return detector.settled(with: profile)
        }
    }
}
