import AnnotationModel
import SwiftUI

/// One-click colour, the way CleanShot and Screendrop lay out style.
struct EditorSwatchStrip: View {
    let selected: AnnotationColor
    let onSelect: (AnnotationColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(AnnotationColor.annotationSwatches.enumerated()), id: \.offset) { _, colour in
                Button {
                    onSelect(colour)
                } label: {
                    Circle()
                        .fill(Color(colour))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isSelected(colour) ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: isSelected(colour) ? 2 : 1
                                )
                        }
                        .overlay {
                            if colour == .white {
                                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour")
                .accessibilityAddTraits(isSelected(colour) ? .isSelected : [])
            }

            ColorPicker(
                "Custom colour",
                selection: Binding(
                    get: { Color(selected) },
                    set: { onSelect(AnnotationColor($0)) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 28, height: 22)
        }
    }

    private func isSelected(_ colour: AnnotationColor) -> Bool {
        abs(colour.red - selected.red) < 0.02
            && abs(colour.green - selected.green) < 0.02
            && abs(colour.blue - selected.blue) < 0.02
    }
}

struct EditorCopiedToast: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// The stroke-width presets from docs/03 §3, as one row of dots.
///
/// The spec lists 2/4/6/10/16 and the constant for them shipped with no caller, so the only
/// way to a round stroke width was to land a slider on one — which on a 1–32 track is a
/// three-pixel target for the value people actually want. Every annotation tool in every
/// other editor offers these directly, and a dot drawn at the width it sets says what it
/// does without a label.
///
/// The slider stays: the presets are the common answers, not the only ones.
struct EditorWidthPresets: View {
    let selected: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(StrokeStyle.widthPresets, id: \.self) { width in
                Button {
                    onSelect(width)
                } label: {
                    Circle()
                        .fill(Color.primary.opacity(isSelected(width) ? 0.95 : 0.55))
                        // Drawn at a fraction of the width it sets, so the row reads as a
                        // scale rather than five identical buttons.
                        .frame(width: dotSize(for: width), height: dotSize(for: width))
                        .frame(width: 22, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(isSelected(width) ? 0.12 : 0))
                        }
                }
                .buttonStyle(.plain)
                .help("\(Int(width)) pt")
                .accessibilityLabel("Stroke width \(Int(width)) points")
                .accessibilityAddTraits(isSelected(width) ? .isSelected : [])
            }
        }
    }

    /// Within half a point, because the slider produces fractional values and a preset that
    /// only lit up on an exact match would almost never light up.
    private func isSelected(_ width: CGFloat) -> Bool {
        abs(selected - width) < 0.5
    }

    private func dotSize(for width: CGFloat) -> CGFloat {
        // Square-rooted rather than linear: at 16 pt a true-to-scale dot would not fit, and
        // the row only has to communicate order.
        4 + sqrt(width) * 2
    }
}
