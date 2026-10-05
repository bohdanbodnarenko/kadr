import SwiftUI

/// What the pointer and keyboard are doing to a slider, as far as its drawing cares.
struct SliderInteraction: Equatable {
    var isHovering = false
    /// A button is down on the track, whether or not it has moved yet.
    var isPressed = false
    /// The button has moved far enough that the pointer is dragging, not clicking. Until
    /// then a press animates the fill to the pointer; after it the fill *is* the pointer.
    var isScrubbing = false
    var isFocused = false

    /// Anything that makes the handle reach for the pointer.
    var isActive: Bool {
        isHovering || isPressed || isFocused
    }
}

/// The slider's drawing, with no state of its own (docs/09 U1.5).
///
/// A capsule track, an inset capsule fill that stops a gap short of a floating handle, ghost
/// ticks that appear while the control is engaged, the title on the leading edge and the
/// value on the trailing one — either of which steps aside, on a spring, when the handle
/// comes to where it sits. Split from `KadrSlider` so every state can be drawn on demand: the
/// interaction arrives as a value instead of being discovered from a pointer that a test does
/// not have.
struct SliderTrackView<Trailing: View>: View {
    let title: String?
    let geometry: SliderGeometry
    let progress: Double
    let zeroProgress: Double?
    let interaction: SliderInteraction
    let layout: SliderLabelLayout
    let placement: SliderLabelLayout.Placement
    let fontSize: CGFloat
    @ViewBuilder let trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var increasedContrast: Bool {
        contrast == .increased
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(SliderPalette.track(for: colorScheme, increasedContrast: increasedContrast))
            positioned
            labels
        }
        .frame(width: geometry.width, height: geometry.height)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(stroke, lineWidth: interaction.isFocused ? 1 : 0.5)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: interaction.isActive)
    }

    /// The fill, the ticks and the handle: everything that moves with the value, and so
    /// everything that springs to a new one — and stops springing while the pointer drags.
    private var positioned: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(SliderPalette.fill(
                    for: colorScheme,
                    isEngaged: interaction.isPressed || interaction.isFocused,
                    increasedContrast: increasedContrast
                ))
                .frame(width: geometry.fillWidth(progress: progress), height: geometry.fillHeight)
                .padding(.leading, geometry.inset)
            ticks
            handle
        }
        .animation(positionAnimation, value: progress)
    }

    private var handle: some View {
        let height = geometry.fillHeight * (interaction.isActive ? 0.66 : 0.5)
        return Capsule(style: .continuous)
            .fill(SliderPalette.handle(isHovering: interaction.isHovering, isPressed: interaction.isPressed))
            .frame(width: geometry.handleWidth, height: height)
            .scaleEffect(x: interaction.isPressed ? 1.35 : 1)
            .offset(x: geometry.handleCenter(progress: progress) - geometry.handleWidth / 2)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: interaction.isActive)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: interaction.isPressed)
    }

    // MARK: - Ticks

    /// Ghost marks along the track. Each is its own view so it can fade on its own when a
    /// label comes to sit on it or the handle passes over it.
    private var ticks: some View {
        let spans = layout.occupiedSpans(placement)
        let handleX = geometry.handleCenter(progress: progress)
        return ZStack(alignment: .leading) {
            ForEach(SliderTicks.ticks(in: geometry, zeroProgress: zeroProgress), id: \.x) { tick in
                let isClear = SliderTicks.isClear(tick, of: spans, handleX: handleX)
                let width: Double = tick.isZero ? 1.5 : 1
                Capsule()
                    .fill(Color.primary.opacity(tick.isZero ? 0.38 : 0.22))
                    .frame(width: width, height: tick.isZero ? 14 : 10)
                    .offset(x: tick.x - width / 2)
                    .opacity(interaction.isActive && isClear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isClear)
            }
        }
    }

    // MARK: - Labels

    /// The title and the number, each at a fixed end of the track. When the handle reaches
    /// one, it does not slide along the track through the handle: it leaves where it is and
    /// arrives at the opposite end, so the label is never drawn across the bar.
    private var labels: some View {
        let titleX = layout.titleX(placement)
        let valueX = layout.valueRight(placement) - layout.valueBoxWidth
        return ZStack(alignment: .leading) {
            if let title {
                Text(title)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(1)
                    .frame(width: layout.titleShownWidth, alignment: .leading)
                    .offset(x: titleX)
                    .id(placement.titleAtTrailing)
                    .transition(.labelHop(toward: placement.titleAtTrailing ? -1 : 1))
            }
            trailing
                .offset(x: valueX)
                .id(placement.valueAtLeading)
                .transition(.labelHop(toward: placement.valueAtLeading ? 1 : -1))
        }
        .frame(width: geometry.width, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84), value: placement)
    }

    private var positionAnimation: Animation? {
        guard !reduceMotion, !interaction.isScrubbing else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.82)
    }

    private var stroke: Color {
        interaction.isFocused
            ? Color.accentColor.opacity(0.72)
            : SliderPalette.border(isActive: interaction.isActive, increasedContrast: increasedContrast)
    }
}

/// The slider's colours, in one place so the light and dark tables stay side by side.
///
/// The resting values were raised and given an Increase Contrast branch: a 9% fill on a 4%
/// track was nearly invisible in light mode, so the value read only from the label
/// (docs/18 SH-11).
enum SliderPalette {
    static func track(for colorScheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        if increasedContrast {
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
        }
        return colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
    }

    /// Neutral at rest, tinted while the pointer or keyboard has hold of the control.
    static func fill(for colorScheme: ColorScheme, isEngaged: Bool, increasedContrast: Bool = false) -> Color {
        if isEngaged {
            return Color.accentColor.opacity(increasedContrast ? 0.45 : colorScheme == .dark ? 0.28 : 0.22)
        }
        if increasedContrast {
            return Color.primary.opacity(colorScheme == .dark ? 0.32 : 0.28)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.17 : 0.15)
    }

    static func handle(isHovering: Bool, isPressed: Bool) -> Color {
        Color.primary.opacity(isPressed ? 0.88 : isHovering ? 0.62 : 0.38)
    }

    static func border(isActive: Bool, increasedContrast: Bool = false) -> Color {
        if increasedContrast {
            return Color.primary.opacity(isActive ? 0.55 : 0.40)
        }
        return Color.primary.opacity(isActive ? 0.16 : 0.10)
    }
}

/// How a label leaves one end of the track and arrives at the other (docs/09 U1.5).
///
/// It is the same effect on the way out and on the way in, pointed at the end the label is
/// not at: a label leaving drifts toward its destination as it fades and softens, and one
/// arriving comes in from the direction it left. Read together, the label crosses the track
/// without ever being drawn across it — which is the point, since the handle is in the way.
private struct LabelHop: ViewModifier {
    var dx: CGFloat
    var opacity: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .opacity(opacity)
            .blur(radius: blur)
    }
}

extension AnyTransition {
    /// `toward` is the direction of the label's other end: +1 for the trailing end, -1 for
    /// the leading one.
    static func labelHop(toward direction: CGFloat) -> AnyTransition {
        .modifier(
            active: LabelHop(dx: direction * 16, opacity: 0, blur: 3),
            identity: LabelHop(dx: 0, opacity: 1, blur: 0)
        )
    }
}
