import AppKit
import SwiftUI

/// Shared metrics for the floating recording / All-in-One islands.
///
/// Sized off the control row rather than a caption: the icons carry the bar and the
/// tooltip carries the naming.
enum RecordingBarMetrics {
    static let controlSize: CGFloat = 40
    static let iconSize: CGFloat = 17
    static let barHeight: CGFloat = 52
    static let cornerRadius: CGFloat = 16
    static let controlSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 6

    static let tooltipPillHeight: CGFloat = 24
    /// Space between the top of the bar and the bottom of the tooltip pill.
    static let tooltipGap: CGFloat = 8
    /// Transparent slack above the bar for the tooltip pill and its shadow.
    static let tooltipReserve: CGFloat = tooltipGap + tooltipPillHeight + 16
    /// Room so Liquid Glass's shadow is not clipped by the panel.
    static let shadowSlack: CGFloat = 28

    /// The recording panel is this size in every mode, so a morph only changes the bar's
    /// own width — never the window's. Wide enough for the picker plus tooltip overhang.
    static let panelWidth: CGFloat = 760
    static let panelHeight: CGFloat = tooltipReserve + barHeight + shadowSlack

    /// Fallback when SwiftUI has not laid out yet — a 0×0 panel is invisible.
    static let fallbackSize = CGSize(width: 520, height: 108)

    /// AppKit label colours, not `.primary`: hierarchical styles resolve against the
    /// control active state, and this bar lives in a panel that is rarely key.
    static let activeTint = Color(nsColor: .labelColor)
    /// A control that is off is dimmed, never shrunk.
    static let inactiveTint = Color(nsColor: .labelColor).opacity(0.4)
    static let stroke = Color(nsColor: .separatorColor)
    /// Hairline that defines the glass edge against a background of the same brightness.
    static let edge = Color(nsColor: .labelColor).opacity(0.12)
    static let recordTint = Color(nsColor: .systemRed)
    static let hoverFill = Color(nsColor: .labelColor).opacity(0.11)
    static let hoverDiameter: CGFloat = 32

    /// Picker → countdown → live. Enough travel to read as one bar changing shape rather
    /// than two bars swapping.
    static let modeChange = Animation.spring(response: 0.34, dampingFraction: 0.86)

    static var tooltipAnimation: Animation {
        AccessibilityChrome.reduceMotion
            ? AccessibilityChrome.reduced
            : .easeOut(duration: 0.12)
    }

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    static func resolvedIslandSize(fitting: CGSize) -> CGSize {
        if fitting.width > 1, fitting.height > 1 {
            return fitting
        }
        return fallbackSize
    }
}

/// `nonisolated`: read from `onGeometryChange`'s Sendable transform closure.
nonisolated enum RecordingBarCoordinateSpace {
    /// The bar itself; the tooltip pill and control frames are measured in it.
    static let bar = "recordingIsland"
    /// The whole panel, which the bar is measured in for hit-testing.
    static let panel = "recordingIslandPanel"
}

struct RecordingBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(RecordingBarMetrics.stroke)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 5)
    }
}

extension View {
    /// The bar's glass: clipped to the same shape so a morph hides controls behind the
    /// narrowing edge instead of letting them spill past it.
    func recordingBarGlass() -> some View {
        clipShape(RecordingBarMetrics.shape)
            .kadrLiquidGlass(in: RecordingBarMetrics.shape, interactive: false)
            .overlay {
                RecordingBarMetrics.shape.strokeBorder(RecordingBarMetrics.edge, lineWidth: 0.5)
            }
    }
}

/// One glass capsule sized to its content, for panels that follow their fitting size
/// (All-in-One). The recording bar builds the same glass inside a fixed panel instead.
struct RecordingIslandSurface<Content: View>: View {
    @State private var tooltip = RecordingBarTooltipModel()
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, RecordingBarMetrics.horizontalPadding)
            .padding(.vertical, (RecordingBarMetrics.barHeight - RecordingBarMetrics.controlSize) / 2)
            .frame(minHeight: RecordingBarMetrics.barHeight)
            .recordingBarGlass()
            .coordinateSpace(.named(RecordingBarCoordinateSpace.bar))
            .overlay { RecordingBarTooltipLayer(tooltip: tooltip) }
            .padding(.top, RecordingBarMetrics.tooltipReserve)
            .padding(RecordingBarMetrics.shadowSlack)
            .fixedSize()
            .environment(tooltip)
    }
}

/// Positioned off the hovered control's measured frame, so it tracks a mode swap.
struct RecordingBarTooltipLayer: View {
    let tooltip: RecordingBarTooltipModel
    /// Above the floating bar; below the notch island, where above is off the display.
    var edge: VerticalEdge = .top

    var body: some View {
        GeometryReader { proxy in
            if let target = tooltip.visible {
                RecordingBarTooltipPill(text: target.text)
                    .position(x: target.frame.midX, y: pillCentre(in: proxy.size))
            }
        }
        .allowsHitTesting(false)
        // Keyed on the id as well as the text so sliding along the bar glides the pill
        // from control to control rather than cross-fading it in place.
        .animation(RecordingBarMetrics.tooltipAnimation, value: tooltip.visible?.id)
        .animation(RecordingBarMetrics.tooltipAnimation, value: tooltip.visible?.text)
    }

    private func pillCentre(in size: CGSize) -> CGFloat {
        let offset = RecordingBarMetrics.tooltipGap + RecordingBarMetrics.tooltipPillHeight / 2
        return edge == .top ? -offset : size.height + offset
    }
}

struct RecordingBarTooltipTarget: Equatable {
    var id: String
    var text: String
    var frame: CGRect
}

@Observable
@MainActor
final class RecordingBarTooltipModel {
    private(set) var visible: RecordingBarTooltipTarget?
    private var hovered: String?
    private var isWarm = false
    private var showTask: Task<Void, Never>?
    private var coolTask: Task<Void, Never>?

    func hover(id: String, text: String, frame: CGRect) {
        hovered = id
        showTask?.cancel()
        coolTask?.cancel()
        guard !isWarm else {
            visible = RecordingBarTooltipTarget(id: id, text: text, frame: frame)
            return
        }
        showTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, hovered == id else { return }
            visible = RecordingBarTooltipTarget(id: id, text: text, frame: frame)
            isWarm = true
        }
    }

    func endHover(id: String) {
        guard hovered == id else { return }
        hovered = nil
        showTask?.cancel()
        visible = nil
        coolTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, hovered == nil else { return }
            isWarm = false
        }
    }

    func dismiss() {
        hovered = nil
        showTask?.cancel()
        withTransaction(Transaction(animation: nil)) {
            visible = nil
        }
    }
}

struct RecordingBarTooltipPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(RecordingBarMetrics.activeTint)
            .lineLimit(1)
            .fixedSize()
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

/// A quiet control. The island's glass is the only glass — icons stay ink.
struct RecordingBarCircleButton: View {
    let symbol: String
    var help: String = ""
    var isOn: Bool = true
    var tint: Color?
    let action: () -> Void

    @Environment(RecordingBarTooltipModel.self) private var tooltip: RecordingBarTooltipModel?

    var body: some View {
        Button {
            tooltip?.dismiss()
            action()
        } label: {
            RecordingBarIcon(symbol: symbol, isOn: isOn, tint: tint)
                .recordingBarHoverTooltip(help)
        }
        .buttonStyle(RecordingBarPressStyle())
        .accessibilityLabel(help)
    }
}

struct RecordingBarIcon: View {
    let symbol: String
    var isOn: Bool = true
    var tint: Color?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: RecordingBarMetrics.iconSize, weight: .regular))
            .foregroundStyle(
                (tint ?? (isOn ? RecordingBarMetrics.activeTint : RecordingBarMetrics.inactiveTint))
                    .opacity(isEnabled ? 1 : 0.3)
            )
            .frame(width: RecordingBarMetrics.controlSize, height: RecordingBarMetrics.controlSize)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The red commit control — Record, Skip during countdown, Stop while recording.
///
/// The same target as every other control, carried by tint alone: a filled red disc read
/// as a second, heavier bar sitting inside the first.
struct RecordingBarFilledCircleButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        RecordingBarCircleButton(
            symbol: symbol,
            help: help,
            tint: RecordingBarMetrics.recordTint,
            action: action
        )
    }
}

/// Live loudness while recording (CleanShot §13.3). No animation of its own — the
/// control bar already refreshes from the sample buffers.
struct RecordingAudioMeter: View {
    var level: Float
    /// Tighter bars for the notch island so hover only needs a small width grow.
    var compact: Bool = false

    var body: some View {
        let barWidth: CGFloat = compact ? 2 : 3
        let spacing: CGFloat = compact ? 1 : 2
        HStack(spacing: spacing) {
            ForEach(0 ..< 5, id: \.self) { index in
                Capsule()
                    .fill(level > Float(index) / 5 ? Color.green : Color.primary.opacity(0.18))
                    .frame(
                        width: barWidth,
                        height: compact ? 5 + CGFloat(index) * 2 : 6 + CGFloat(index) * 2.5
                    )
            }
        }
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}

/// A worded choice inside the bar — the inline discard confirmation. Destructive is the
/// filled red capsule; the other stays quiet so the safe answer is not the loud one.
struct RecordingBarCapsuleButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isDestructive ? Color.white : RecordingBarMetrics.activeTint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule().fill(isDestructive ? RecordingBarMetrics.recordTint : RecordingBarMetrics.hoverFill)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// `.plain` still fades for an inactive window, and this bar lives in a
/// non-activating panel — so we own the style or every icon looks disabled.
struct RecordingBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private struct RecordingBarHoverTooltipModifier: ViewModifier {
    let text: String
    @Environment(RecordingBarTooltipModel.self) private var tooltip: RecordingBarTooltipModel?
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // A background so the puck never takes part in layout.
            .background {
                Circle()
                    .fill(RecordingBarMetrics.hoverFill)
                    .frame(
                        width: RecordingBarMetrics.hoverDiameter,
                        height: RecordingBarMetrics.hoverDiameter
                    )
                    .opacity(hovering ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(RecordingBarCoordinateSpace.bar))
            } action: { frame = $0 }
            .background {
                RecordingBarHoverTracking(isEnabled: isEnabled) { setHovering($0) }
            }
            .onChange(of: text) { _, new in
                guard hovering else { return }
                tooltip?.hover(id: new, text: new, frame: frame)
            }
            .onDisappear {
                // A mode morph swaps controls out under a pointer that never left the bar.
                tooltip?.endHover(id: text)
            }
            .accessibilityHint(text)
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        if value {
            tooltip?.hover(id: text, text: text, frame: frame)
        } else {
            tooltip?.endHover(id: text)
        }
    }
}

/// Tracking area marked `.activeAlways`: `.onHover` is silent in a
/// non-activating panel that is usually not the active app.
private struct RecordingBarHoverTracking: NSViewRepresentable {
    var isEnabled: Bool
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecordingBarHoverView {
        let view = RecordingBarHoverView()
        view.onChange = onChange
        view.isTrackingEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: RecordingBarHoverView, context: Context) {
        view.onChange = onChange
        view.isTrackingEnabled = isEnabled
    }

    static func dismantleNSView(_ view: RecordingBarHoverView, coordinator: ()) {
        view.endHover()
    }
}

final class RecordingBarHoverView: NSView {
    var onChange: ((Bool) -> Void)?
    var isTrackingEnabled = true {
        didSet {
            if !isTrackingEnabled {
                endHover()
            }
        }
    }

    private var isHovering = false

    /// The one control, at most, whose hover owns the pointing hand. Class-level so the
    /// claim hands over atomically when the pointer slides to the next control.
    private static weak var handOwner: RecordingBarHoverView?

    /// `orderOut` sends no exit events; the bar's owner ends a live hover by hand.
    static func endActiveHover() {
        handOwner?.endHover()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        beginHover()
    }

    /// Re-claimed on every move: entry can be missed (the bar appearing under a still
    /// pointer) and anything may have reset the cursor since the last move.
    override func mouseMoved(with event: NSEvent) {
        beginHover()
    }

    override func mouseExited(with event: NSEvent) {
        endHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            endHover()
        }
    }

    private func beginHover() {
        guard isTrackingEnabled else { return }
        claimHand()
        guard !isHovering else { return }
        isHovering = true
        onChange?(true)
    }

    func endHover() {
        releaseHand()
        guard isHovering else { return }
        isHovering = false
        onChange?(false)
    }

    /// Deferred a turn: AppKit and the hosting view reassert the arrow during the event's
    /// dispatch, so a cursor set inline is overwritten before it is seen.
    private func claimHand() {
        Self.handOwner = self
        Task { @MainActor [weak self] in
            guard let self, Self.handOwner === self else { return }
            NSCursor.pointingHand.set()
        }
    }

    /// Restores the arrow only if no other control claimed the hand in the same turn.
    private func releaseHand() {
        guard Self.handOwner === self else { return }
        Self.handOwner = nil
        Task { @MainActor in
            guard Self.handOwner == nil else { return }
            NSCursor.arrow.set()
        }
    }
}

extension View {
    func recordingIslandSurface() -> some View {
        RecordingIslandSurface { self }
    }

    func recordingBarHoverTooltip(_ text: String) -> some View {
        modifier(RecordingBarHoverTooltipModifier(text: text))
    }

    func recordingBarMenu(tooltip: String) -> some View {
        menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(RecordingBarPressStyle())
            .recordingBarHoverTooltip(tooltip)
    }
}
