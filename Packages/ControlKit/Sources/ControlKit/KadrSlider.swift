import SwiftUI

/// Kadr's one numeric control, in Settings and in the editor's inspector (docs/09 U1.5).
///
/// A pill track with the title inside it and the value on its trailing edge. Dragging
/// anywhere on the track sets the value from the pointer's position — there is no thumb to
/// chase — and the handle that floats past the fill stays under the cursor. Hover, focus and
/// press make the handle reach and bring up ghost ticks; signed ranges get a soft zero detent,
/// one of the ticks. When the handle comes to where the title or the number sits, that label
/// steps aside on a spring instead of being run over.
///
/// Click the number to type an exact value: it accepts the unit's suffix ("45%", "12px",
/// "30deg", "1.5×") and a bare number. Arrow keys on the track step by one of whatever the
/// value shows (or by `step`), and Return starts typing.
///
/// Size follows `controlSize`, so a compact strip and a roomy settings row are the same
/// control at two sizes rather than two controls.
public struct KadrSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let format: SliderValueFormat
    private let step: Double?
    private let showsTitle: Bool
    private let onEditingEnded: () -> Void

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedPart: FocusedPart?
    @State private var draftText = ""
    @State private var editingBaselineText = ""
    @State private var interaction = SliderInteraction()
    @State private var placement = SliderLabelLayout.Placement()
    /// The press began on the number, so a click there means "type" and a drag still scrubs.
    @State private var pressedOnValue = false

    private enum FocusedPart: Hashable {
        case track
        case value
    }

    /// How far a press can wander and still be a click on the number.
    private static let clickSlop: CGFloat = 3

    /// - Parameters:
    ///   - title: Drawn inside the track, and always the accessibility name.
    ///   - step: The grid a dragged value snaps to and an arrow key moves by. Omit for a
    ///     continuous drag and one displayed unit per key press.
    ///   - showsTitle: False where a label already sits beside the control, as in a
    ///     Settings row.
    ///   - onEditingEnded: Called when a drag or an edit ends, so a caller can settle an
    ///     expensive preview (docs/09 U1.3).
    public init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: SliderValueFormat = .percent,
        step: Double? = nil,
        showsTitle: Bool = true,
        onEditingEnded: @escaping () -> Void = {}
    ) {
        self.title = title
        _value = value
        self.range = range
        self.format = format
        self.step = step
        self.showsTitle = showsTitle
        self.onEditingEnded = onEditingEnded
    }

    public var body: some View {
        GeometryReader { proxy in
            let geometry = SliderGeometry(width: proxy.size.width, height: metrics.height)
            track(geometry)
                .onAppear { settlePlacement(geometry) }
                .onChange(of: value) { _, _ in refreshPlacement(geometry) }
                .onChange(of: geometry.width) { _, _ in refreshPlacement(geometry) }
        }
        .frame(height: metrics.height)
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.45)
        .onAppear(perform: syncDraftText)
        .onDisappear {
            if focusedPart == .value {
                commitDraftText()
            }
        }
        .onChange(of: value) { _, _ in syncDraftText() }
        .onChange(of: focusedPart) { oldPart, newPart in
            interaction.isFocused = newPart != nil
            if newPart == .value {
                beginValueEditing()
            } else if oldPart == .value {
                commitDraftText()
            }
        }
    }

    // MARK: - Track

    private var progress: Double {
        SliderMapping.progress(of: value, in: range)
    }

    /// The number's width as drawn now.
    private var valueTextWidth: Double {
        SliderTextMetrics.width(
            of: format.string(for: value),
            fontSize: metrics.fontSize,
            monospacedDigits: true
        )
    }

    /// The fixed box the number, or the field it becomes, lives in.
    private var valueBoxWidth: Double {
        max(metrics.valueWidth, valueTextWidth)
    }

    /// The widest the number gets over the whole range, so the title beside it stays put.
    private var valueReserve: Double {
        let ends = [range.lowerBound, range.upperBound]
        let widths = ends.map { end in
            SliderTextMetrics.width(of: format.string(for: end), fontSize: metrics.fontSize, monospacedDigits: true)
        }
        return widths.max() ?? valueTextWidth
    }

    private func labelLayout(_ geometry: SliderGeometry) -> SliderLabelLayout {
        SliderLabelLayout(
            geometry: geometry,
            textInset: metrics.textInset,
            titleWidth: showsTitle
                ? SliderTextMetrics.width(of: title, fontSize: metrics.fontSize)
                : 0,
            valueWidth: valueTextWidth,
            valueBoxWidth: valueBoxWidth,
            valueReserve: valueReserve
        )
    }

    /// Re-decide which labels are out of the handle's way, keeping the old answer where the
    /// handle sits on a boundary.
    private func refreshPlacement(_ geometry: SliderGeometry) {
        // A label that jumps while it is being typed into would take the field with it.
        guard focusedPart != .value else { return }
        let next = labelLayout(geometry).resolved(from: placement, progress: progress)
        if next != placement {
            placement = next
        }
    }

    /// The first placement, taken without the spring: a slider that appears at 5% should
    /// already have its title out of the handle's way, not glide there.
    private func settlePlacement(_ geometry: SliderGeometry) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            refreshPlacement(geometry)
        }
    }

    private func track(_ geometry: SliderGeometry) -> some View {
        SliderTrackView(
            title: showsTitle ? title : nil,
            geometry: geometry,
            progress: progress,
            zeroProgress: SliderMapping.zeroProgress(in: range),
            interaction: interaction,
            layout: labelLayout(geometry),
            placement: placement,
            fontSize: metrics.fontSize
        ) {
            valueLabel
        }
        .contentShape(Capsule(style: .continuous))
        .gesture(scrub(geometry))
        .onHover { interaction.isHovering = $0 }
        .allowsHitTesting(isEnabled)
        .pointerStyleColumnResize(enabled: isEnabled)
        .focusable(isEnabled)
        .focused($focusedPart, equals: .track)
        .onKeyPress(.leftArrow) { nudge(steps: -1) }
        .onKeyPress(.rightArrow) { nudge(steps: 1) }
        .onKeyPress(.downArrow) { nudge(steps: -1) }
        .onKeyPress(.upArrow) { nudge(steps: 1) }
        .onKeyPress(.return) { beginTyping() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format.string(for: value))
        .accessibilityHint("Drag horizontally to adjust, or click the value to type one")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustValue(by: stepSize)
            case .decrement: adjustValue(by: -stepSize)
            @unknown default: break
            }
        }
    }

    private func scrub(_ geometry: SliderGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !interaction.isPressed {
                    beginPress(at: drag.startLocation.x, geometry: geometry)
                }
                let moved = hypot(drag.translation.width, drag.translation.height) > Self.clickSlop
                if moved {
                    interaction.isScrubbing = true
                }
                // A press on the number that has not moved is a click on it: leave the
                // value alone until it turns into a drag.
                guard moved || !pressedOnValue else { return }
                updateValue(for: drag.location.x, geometry: geometry)
            }
            .onEnded { _ in
                let wasClickOnValue = pressedOnValue && !interaction.isScrubbing
                interaction.isPressed = false
                interaction.isScrubbing = false
                pressedOnValue = false
                if wasClickOnValue {
                    _ = beginTyping()
                } else {
                    onEditingEnded()
                }
            }
    }

    private func beginPress(at locationX: CGFloat, geometry: SliderGeometry) {
        let onValue = labelLayout(geometry).isOnValue(x: Double(locationX), placement: placement)
        if focusedPart == .value {
            commitDraftText()
        }
        focusedPart = .track
        interaction.isPressed = true
        pressedOnValue = onValue
    }

    // MARK: - Value

    /// The number — or a field while it is being typed.
    ///
    /// It changes the instant the value does. A rolling-digit transition was tried and looked
    /// wrong in exactly the way that matters for a readout: going from 29% to 30% it passed
    /// through 39%, and when the number moved aside for the handle at the same moment the
    /// digits came out in the wrong order. The motion is in the fill, the handle and the
    /// label's spring; the number is just always true.
    private var valueLabel: some View {
        Group {
            if focusedPart == .value {
                TextField(title, text: $draftText)
                    // The title is the field's accessibility name, not something to draw:
                    // inside a `Form` — which draws a text field's label — the row came out
                    // as the name stacked over the number.
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedPart, equals: .value)
                    .onSubmit {
                        commitDraftText()
                        focusedPart = nil
                    }
                    .onExitCommand {
                        draftText = editingBaselineText
                        focusedPart = nil
                    }
                    .onKeyPress(.upArrow) { nudge(steps: 1) }
                    .onKeyPress(.downArrow) { nudge(steps: -1) }
                    .accessibilityLabel("\(title) value")
            } else {
                Text(format.string(for: value))
                    .help("Click to type an exact value for \(title)")
            }
        }
        .font(.system(size: metrics.fontSize, weight: .medium).monospacedDigit())
        .foregroundStyle(.primary.opacity(0.82))
        .lineLimit(1)
        .fixedSize()
        .frame(width: valueBoxWidth, alignment: .trailing)
    }

    private func beginTyping() -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        focusedPart = .value
        return .handled
    }

    // MARK: - Setting

    /// What one arrow key or one VoiceOver increment moves by, in stored units.
    private var stepSize: Double {
        step ?? format.step
    }

    private func updateValue(for locationX: CGFloat, geometry: SliderGeometry) {
        let dragged = SliderMapping.value(
            at: geometry.travelledX(for: Double(locationX)),
            width: geometry.travelLength,
            range: range
        )
        setValue(dragged)
    }

    /// One arrow-key press, through the format's own arithmetic.
    private func nudge(steps: Int) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        if focusedPart == .value {
            commitDraftText()
        }
        setValue(format.stepped(value, by: steps, stepSize: step))
        onEditingEnded()
        return .handled
    }

    private func adjustValue(by delta: Double) {
        guard delta.isFinite else { return }
        setValue(value + delta)
        onEditingEnded()
    }

    private func setValue(_ proposed: Double) {
        guard isEnabled,
              proposed.isFinite,
              range.lowerBound.isFinite,
              range.upperBound.isFinite
        else { return }
        let snapped = SliderMapping.snapped(proposed, step: step, in: range)
        guard snapped != value else { return }
        value = snapped
    }

    // MARK: - Typing

    private func syncDraftText() {
        if focusedPart == .value {
            beginValueEditing()
        } else {
            draftText = format.string(for: value)
        }
    }

    private func beginValueEditing() {
        let editingText = format.editingString(for: value)
        editingBaselineText = editingText
        draftText = editingText
    }

    private func commitDraftText() {
        guard draftText != editingBaselineText else {
            syncDraftText()
            return
        }
        guard let parsed = format.value(from: draftText) else {
            syncDraftText()
            return
        }
        setValue(parsed)
        editingBaselineText = format.editingString(for: value)
        syncDraftText()
        onEditingEnded()
    }

    // MARK: - Size

    private struct Metrics {
        let height: CGFloat
        let fontSize: CGFloat
        let textInset: CGFloat

        /// Wide enough for "+180°", "100%" and "3840 pt" at the value font.
        var valueWidth: CGFloat {
            fontSize * 5
        }
    }

    private var metrics: Metrics {
        switch controlSize {
        case .mini: Metrics(height: 20, fontSize: 10, textInset: 8)
        case .small: Metrics(height: 24, fontSize: 11, textInset: 9)
        case .large, .extraLarge: Metrics(height: 40, fontSize: 13, textInset: 14)
        default: Metrics(height: 32, fontSize: 12, textInset: 12)
        }
    }
}

private extension View {
    /// macOS 15's column-resize pointer; a no-op on 14, where the drag still works.
    @ViewBuilder
    func pointerStyleColumnResize(enabled: Bool) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(enabled ? PointerStyle.columnResize : nil)
        } else {
            self
        }
    }
}
