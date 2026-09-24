import SwiftUI

/// Positioned off the hovered control's measured frame, so it tracks a mode swap.
struct RecordingBarTooltipLayer: View {
    let tooltip: RecordingBarTooltipModel
    /// Above the floating bar; below the notch island, where above is off the display.
    var edge: VerticalEdge = .top
    @State private var pillWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            if let target = tooltip.visible {
                RecordingBarTooltipPill(text: target.text, key: target.key)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                    .position(x: pillCentreX(for: target, in: proxy.size), y: pillCentre(in: proxy.size))
            }
        }
        .allowsHitTesting(false)
        // Keyed on the id as well as the text so sliding along the bar glides the pill
        // from control to control rather than cross-fading it in place.
        .animation(RecordingBarMetrics.tooltipAnimation, value: tooltip.visible?.id)
        .animation(RecordingBarMetrics.tooltipAnimation, value: tooltip.visible?.text)
        .animation(RecordingBarMetrics.tooltipAnimation, value: tooltip.visible?.key)
    }

    /// Centred on the control, but kept inside the panel: the window only extends
    /// `shadowSlack` past the glass, so a wide label over an end control was clipped.
    private func pillCentreX(for target: RecordingBarTooltipTarget, in size: CGSize) -> CGFloat {
        Self.clampedCentreX(
            controlMidX: target.frame.midX,
            pillWidth: pillWidth,
            barWidth: size.width,
            overhang: RecordingBarMetrics.shadowSlack - 4
        )
    }

    static func clampedCentreX(
        controlMidX: CGFloat, pillWidth: CGFloat, barWidth: CGFloat, overhang: CGFloat
    ) -> CGFloat {
        let half = pillWidth / 2
        let low = -overhang + half
        let high = barWidth + overhang - half
        // A pill wider than the whole panel stays centred on the bar.
        guard low <= high else { return barWidth / 2 }
        return min(max(controlMidX, low), high)
    }

    private func pillCentre(in size: CGSize) -> CGFloat {
        let offset = RecordingBarMetrics.tooltipGap + RecordingBarMetrics.tooltipPillHeight / 2
        return edge == .top ? -offset : size.height + offset
    }
}

struct RecordingBarTooltipTarget: Equatable {
    var id: String
    var text: String
    /// The single key that triggers the control, shown as a keycap in the pill.
    var key: String?
    var frame: CGRect
}

@Observable
@MainActor
final class RecordingBarTooltipModel {
    private(set) var visible: RecordingBarTooltipTarget?
    private var hovered: String?
    private var isWarm = false
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var coolTask: Task<Void, Never>?

    /// How long a pill outlives its control's hover before it fades.
    ///
    /// Sliding from one control to the next delivers the old control's exit before the new
    /// one's entry about half the time. Hiding on the exit removed the pill and inserted a
    /// new one a moment later, so for the length of the fade there were two pills on
    /// screen — the old one leaving, the new one arriving. Waiting a beat lets the entry
    /// arrive first, and the one pill moves instead.
    static let hideGrace: Duration = .milliseconds(90)

    func hover(id: String, text: String, key: String? = nil, frame: CGRect) {
        hovered = id
        showTask?.cancel()
        hideTask?.cancel()
        coolTask?.cancel()
        guard !isWarm else {
            visible = RecordingBarTooltipTarget(id: id, text: text, key: key, frame: frame)
            return
        }
        showTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, hovered == id else { return }
            visible = RecordingBarTooltipTarget(id: id, text: text, key: key, frame: frame)
            isWarm = true
        }
    }

    func endHover(id: String) {
        guard hovered == id else { return }
        hovered = nil
        showTask?.cancel()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.hideGrace)
            guard !Task.isCancelled, hovered == nil else { return }
            visible = nil
            coolTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, hovered == nil else { return }
                isWarm = false
            }
        }
    }

    func dismiss() {
        hovered = nil
        showTask?.cancel()
        hideTask?.cancel()
        withTransaction(Transaction(animation: nil)) {
            visible = nil
        }
    }
}

struct RecordingBarTooltipPill: View {
    let text: String
    var key: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RecordingBarMetrics.activeTint)
                .lineLimit(1)
                .fixedSize()
            if let key {
                RecordingBarKeycap(key: key)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: RecordingBarMetrics.tooltipPillHeight)
        .kadrLiquidGlass(
            in: RoundedRectangle(cornerRadius: 8, style: .continuous),
            interactive: false
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RecordingBarMetrics.edge, lineWidth: 0.5)
        }
        .transition(.opacity)
    }
}

/// A key, drawn the way macOS draws one in a menu: a quiet rounded cap beside the name.
///
/// Only in the hover pill. Keycaps printed under every control made the island look like
/// a keyboard overlay; the pill is where somebody who wants the shortcut is already looking.
struct RecordingBarKeycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(RecordingBarMetrics.activeTint.opacity(0.75))
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(RecordingBarMetrics.hoverFill)
            }
            .accessibilityHidden(true)
    }
}
