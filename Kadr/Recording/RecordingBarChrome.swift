import AppKit
import ControlKit
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
    /// Stronger under Increase Contrast (docs/18 X-3).
    static var edge: Color {
        let opacity = KadrFill.opacity(.stroke, increaseContrast: KadrAccessibility.increaseContrast)
        return Color(nsColor: .labelColor).opacity(opacity)
    }

    static let recordTint = Color(nsColor: .systemRed)

    static var hoverFill: Color {
        Color(nsColor: .labelColor).opacity(KadrAccessibility.increaseContrast ? 0.2 : 0.11)
    }

    static let hoverDiameter: CGFloat = 32

    /// Picker → countdown → live. Enough travel to read as one bar changing shape rather
    /// than two bars swapping.
    static let modeChange = KadrMotion.panel

    static var tooltipAnimation: Animation {
        AccessibilityChrome.reduceMotion ? KadrMotion.reduced : KadrMotion.hover
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

/// A quiet control. The island's glass is the only glass — icons stay ink.
struct RecordingBarCircleButton: View {
    let symbol: String
    var help: String = ""
    /// Shown as a keycap in the hover pill when the control has a single-key shortcut.
    var key: String?
    /// Nil for an action; true or false for a toggle, which then shows its state by more
    /// than a fainter tint (docs/18 REC P3).
    var isOn: Bool?
    var tint: Color?
    let action: () -> Void

    @Environment(RecordingBarTooltipModel.self) private var tooltip: RecordingBarTooltipModel?

    var body: some View {
        Button {
            tooltip?.dismiss()
            action()
        } label: {
            RecordingBarIcon(symbol: symbol, isOn: isOn, tint: tint)
                .recordingBarHoverTooltip(help, key: key)
        }
        .buttonStyle(RecordingBarPressStyle())
        .accessibilityLabel(help)
    }
}

struct RecordingBarIcon: View {
    let symbol: String
    /// Nil for an action; a toggle that is on also sits on a faint plate, so on and off
    /// differ by shape as well as by how bright the glyph is — which a low-contrast display
    /// or Differentiate Without Colour cannot rely on (docs/18 REC P3).
    var isOn: Bool?
    var tint: Color?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KadrRadius.large, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: RecordingBarMetrics.iconSize, weight: .regular))
            .foregroundStyle(
                (tint ?? (isOn != false ? RecordingBarMetrics.activeTint : RecordingBarMetrics.inactiveTint))
                    .opacity(isEnabled ? 1 : 0.3)
            )
            .frame(width: RecordingBarMetrics.controlSize, height: RecordingBarMetrics.controlSize)
            .background {
                if isOn == true {
                    shape.fill(KadrFill.selected)
                }
            }
            .contentShape(shape)
    }
}

/// The red commit control — Record, Skip during countdown, Stop while recording.
///
/// The same target as every other control, carried by tint alone: a filled red disc read
/// as a second, heavier bar sitting inside the first.
struct RecordingBarFilledCircleButton: View {
    let symbol: String
    var help: String = ""
    /// Shown under the control on hover, the way every other bar button shows its key.
    var key: String?
    let action: () -> Void

    var body: some View {
        RecordingBarCircleButton(
            symbol: symbol,
            help: help,
            key: key,
            tint: RecordingBarMetrics.recordTint,
            action: action
        )
    }
}

/// Live loudness while recording (CleanShot §13.3). No animation of its own — the
/// control bar already refreshes from the sample buffers.
/// The meter bound to the live level, as its own view so the 10 Hz level redraws only
/// this and not the transport around it (PRD §8).
struct RecordingLiveAudioMeter: View {
    let meter: RecordingAudioMeterModel
    var compact: Bool = false

    var body: some View {
        RecordingAudioMeter(level: meter.level, compact: compact)
    }
}

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
                    .fill(level > Float(index) / 5 ? Self.color(forBar: index) : Color.primary.opacity(0.18))
                    .frame(
                        width: barWidth,
                        height: compact ? 5 + CGFloat(index) * 2 : 6 + CGFloat(index) * 2.5
                    )
            }
        }
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }

    /// The system's green, not a fixed one, so Increase Contrast and the dark notch get
    /// their own shade; the top bar warns in orange that the input is close to clipping
    /// (docs/18 REC P3).
    static func color(forBar index: Int) -> Color {
        index == 4 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)
    }
}

/// A worded choice inside the bar — the inline discard confirmation. Destructive is the
/// filled red capsule; the other stays quiet so the safe answer is not the loud one.
struct RecordingBarCapsuleButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: KadrType.body, weight: .semibold))
            .foregroundStyle(isDestructive ? Color.white : RecordingBarMetrics.activeTint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, KadrSpace.large)
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
    let key: String?
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
                tooltip?.hover(id: new, text: new, key: key, frame: frame)
            }
            .onDisappear {
                // A mode morph swaps controls out under a pointer that never left the bar.
                tooltip?.endHover(id: text)
            }
            // Custom content, not `accessibilityHint`: on macOS SwiftUI keeps a hint in the
            // same slot as `.help`, and shows it as a system tooltip — a second, plainer
            // bubble that turned up a moment after this pill. VoiceOver still reads both.
            .accessibilityCustomContent(Text("Description"), Text(text))
            .modifier(ShortcutAccessibilityContent(key: key))
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        if value {
            tooltip?.hover(id: text, text: text, key: key, frame: frame)
        } else {
            tooltip?.endHover(id: text)
        }
    }
}

/// The shortcut for VoiceOver, only on controls that have one.
private struct ShortcutAccessibilityContent: ViewModifier {
    let key: String?

    func body(content: Content) -> some View {
        if let key {
            content.accessibilityCustomContent(Text("Shortcut"), Text(key), importance: .high)
        } else {
            content
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
    private weak static var handOwner: RecordingBarHoverView?

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
    func recordingBarHoverTooltip(_ text: String, key: String? = nil) -> some View {
        modifier(RecordingBarHoverTooltipModifier(text: text, key: key))
    }

    func recordingBarMenu(tooltip: String, key: String? = nil) -> some View {
        menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(RecordingBarPressStyle())
            .recordingBarHoverTooltip(tooltip, key: key)
    }
}
