import AnnotationModel
import SwiftUI

/// One-click colour and width, the way CleanShot and Screendrop lay out style.
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

/// Stroke width as a row of weights, not a list of "4 pt".
struct EditorStrokeWidthStrip: View {
    let selected: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StrokeStyle.widthPresets, id: \.self) { width in
                Button {
                    onSelect(width)
                } label: {
                    Capsule()
                        .fill(abs(width - selected) < 0.5 ? Color.accentColor : Color.primary)
                        .frame(width: 22, height: max(2, width * 0.45))
                        .frame(width: 28, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    abs(width - selected) < 0.5
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.clear
                                )
                        }
                }
                .buttonStyle(.plain)
                .help("\(Int(width)) pt")
                .accessibilityLabel("\(Int(width)) point stroke")
                .accessibilityAddTraits(abs(width - selected) < 0.5 ? .isSelected : [])
            }
        }
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
