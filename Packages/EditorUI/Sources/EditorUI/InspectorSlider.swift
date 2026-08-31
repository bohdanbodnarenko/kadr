import SwiftUI

/// The editor's standard numeric control (docs/09 U1.5).
///
/// A scrub track with the title inside it, filled from the left, and a value field
/// always visible on the right. Dragging anywhere on the track sets the value from
/// that position — there is no tiny thumb to chase. Hover, focus or drag reveals
/// tick markers; signed ranges get a soft zero detent.
///
/// The field accepts the unit's suffix ("45%", "12px", "30deg", "1.5×") and a bare
/// number. Arrow keys on the track or field step by one of whatever the field shows.
struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: InspectorValueFormat = .percent
    /// Called when a drag ends, so a caller can settle an expensive preview (docs/09 U1.3).
    var onEditingEnded: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedPart: FocusedPart?
    @State private var draftText = ""
    @State private var editingBaselineText = ""
    @State private var isTrackHovering = false
    @State private var isDragging = false

    private enum FocusedPart: Hashable {
        case track
        case value
    }

    var body: some View {
        // A VStack, not a bare HStack: macOS Form splits an HStack into a label column
        // and a wrapping value column, which is what put "12 px" on two lines.
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                GeometryReader { proxy in
                    scrubTrack(width: proxy.size.width)
                }
                .frame(height: InspectorMetrics.sliderHeight)

                valueField
                    .frame(
                        minWidth: InspectorMetrics.sliderValueWidth,
                        idealWidth: InspectorMetrics.sliderValueWidth,
                        maxWidth: InspectorMetrics.sliderValueWidth,
                        minHeight: InspectorMetrics.sliderHeight,
                        maxHeight: InspectorMetrics.sliderHeight
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncDraftText)
        .onDisappear {
            if focusedPart == .value {
                commitDraftText()
            }
        }
        .onChange(of: value) { _, _ in syncDraftText() }
        .onChange(of: focusedPart) { oldPart, newPart in
            if newPart == .value {
                beginValueEditing()
            } else if oldPart == .value {
                commitDraftText()
            }
        }
    }

    // MARK: - Track

    private func scrubTrack(width: CGFloat) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.sliderRadius,
            style: .continuous
        )
        let revealsMarkers = isTrackHovering || isDragging || focusedPart == .track

        return ZStack(alignment: .leading) {
            shape.fill(trackFill)
            Rectangle()
                .fill(positionFill)
                .frame(width: width * CGFloat(normalizedProgress))
                .frame(maxHeight: .infinity)
            InspectorSliderMarkers(
                progress: CGFloat(normalizedProgress),
                zeroProgress: zeroProgress.map { CGFloat($0) }
            )
            .opacity(revealsMarkers ? 1 : 0)
            Text(title)
                .font(.inspectorValue)
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .clipShape(shape)
        .overlay { shape.stroke(trackStroke(revealsMarkers: revealsMarkers), lineWidth: 0.5) }
        .contentShape(shape)
        .gesture(scrub(width: width))
        .onHover { isTrackHovering = $0 }
        .allowsHitTesting(isEnabled)
        .inspectorColumnResizePointer(enabled: isEnabled)
        .focusable(isEnabled)
        .focused($focusedPart, equals: .track)
        .onKeyPress(.leftArrow) { nudge(by: -format.step) }
        .onKeyPress(.rightArrow) { nudge(by: format.step) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: revealsMarkers)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format.string(for: value))
        .accessibilityHint("Drag horizontally to adjust, or edit the value field")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustValue(by: format.step)
            case .decrement: adjustValue(by: -format.step)
            @unknown default: break
            }
        }
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if focusedPart == .value {
                    commitDraftText()
                }
                focusedPart = .track
                isDragging = true
                updateValue(for: drag.location.x, width: width)
            }
            .onEnded { _ in
                isDragging = false
                onEditingEnded()
            }
    }

    // MARK: - Value field

    private var valueField: some View {
        TextField(title, text: $draftText)
            .textFieldStyle(.plain)
            .font(.inspectorNumeric)
            .foregroundStyle(.primary.opacity(0.82))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .truncationMode(.tail)
            .monospacedDigit()
            .padding(.horizontal, 4)
            .focused($focusedPart, equals: .value)
            .onSubmit {
                commitDraftText()
                focusedPart = nil
            }
            .onExitCommand {
                draftText = editingBaselineText
                focusedPart = nil
            }
            .onKeyPress(.upArrow) { nudge(by: format.step) }
            .onKeyPress(.downArrow) { nudge(by: -format.step) }
            .inspectorField(
                height: InspectorMetrics.sliderHeight,
                cornerRadius: InspectorMetrics.sliderRadius
            )
            .overlay {
                if focusedPart == .value {
                    RoundedRectangle(
                        cornerRadius: InspectorMetrics.sliderRadius,
                        style: .continuous
                    )
                    .stroke(Color.accentColor.opacity(0.72), lineWidth: 1)
                }
            }
            .accessibilityLabel("\(title) value")
            .help("Enter an exact value for \(title)")
    }

    // MARK: - Mapping

    private var normalizedProgress: Double {
        InspectorSliderMapping.progress(of: value, in: range)
    }

    private var zeroProgress: Double? {
        InspectorSliderMapping.zeroProgress(in: range)
    }

    private var trackFill: Color {
        InspectorControlPalette.trackFill(for: colorScheme)
    }

    private var positionFill: Color {
        if isDragging || focusedPart == .track {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
        return InspectorControlPalette.selectionFill(for: colorScheme)
    }

    private func trackStroke(revealsMarkers: Bool) -> Color {
        if focusedPart == .track {
            return Color.accentColor.opacity(0.72)
        }
        return Color.primary.opacity(revealsMarkers ? 0.16 : 0.10)
    }

    private func updateValue(for locationX: CGFloat, width: CGFloat) {
        setValue(InspectorSliderMapping.value(
            at: Double(locationX),
            width: Double(width),
            range: range
        ))
    }

    private func nudge(by delta: Double) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        if focusedPart == .value {
            commitDraftText()
        }
        adjustValue(by: delta)
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
        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
    }

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
}
