import AnnotationModel
import AppKit
import SwiftUI

/// One-click colour, the way CleanShot lays out style.
///
/// A wrapping grid rather than a fixed row: at the inspector's narrowest width the old row
/// ran the colour well off the trailing edge.
struct EditorSwatchStrip: View {
    let selected: AnnotationColor
    let onSelect: (AnnotationColor) -> Void
    var defaults: UserDefaults = .standard

    @State private var palette = EditorUserPalette()

    private static let columns = [GridItem(.adaptive(minimum: 24, maximum: 28), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
                ForEach(Array(AnnotationColor.annotationSwatches.enumerated()), id: \.offset) { _, colour in
                    swatch(colour, removable: false)
                }
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, colour in
                    swatch(colour, removable: true)
                }
            }

            HStack(spacing: 8) {
                ColorPicker(
                    "Custom color",
                    selection: Binding(
                        get: { Color(selected) },
                        set: { onSelect(AnnotationColor($0)) }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()

                Button {
                    addSelectedToPalette()
                } label: {
                    Label("Add to Palette", systemImage: "plus")
                }
                .buttonStyle(InspectorButtonStyle(fillsWidth: false))
                .disabled(!palette.canAdd(selected))
                .help("Save this color to your palette. Option-click a saved color to remove it.")

                Spacer(minLength: 0)
            }
        }
        .onAppear {
            palette = EditorUserPalette.load(from: defaults)
        }
    }

    private func swatch(_ colour: AnnotationColor, removable: Bool) -> some View {
        let isSelected = isSelected(colour)
        return Button {
            if removable, NSEvent.modifierFlags.contains(.option) {
                removeFromPalette(colour)
            } else {
                onSelect(colour)
            }
        } label: {
            Circle()
                .fill(Color(colour))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(removable ? "Option-click to remove" : "Color")
        .accessibilityLabel("Color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func addSelectedToPalette() {
        var next = palette
        guard next.add(selected) else { return }
        next.save(to: defaults)
        palette = next
    }

    private func removeFromPalette(_ colour: AnnotationColor) {
        var next = palette
        next.remove(colour)
        next.save(to: defaults)
        palette = next
    }

    private func isSelected(_ colour: AnnotationColor) -> Bool {
        colour.isClose(to: selected)
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
                Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// The stroke-width presets from docs/03 §3, as a segmented track of dots.
///
/// The spec lists 2/4/6/10/16. A dot drawn at a fraction of the width it sets says what it
/// does without a label; the slider below stays for everything in between.
struct EditorWidthPresets: View {
    let selected: CGFloat
    let onSelect: (CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.controlRadius, style: .continuous)
        HStack(spacing: 0) {
            ForEach(StrokeStyle.widthPresets, id: \.self) { width in
                preset(width)
            }
        }
        .padding(InspectorMetrics.controlInset)
        .frame(height: InspectorMetrics.controlHeight)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .overlay(shape.strokeBorder(InspectorControlPalette.border, lineWidth: 0.5))
    }

    private func preset(_ width: CGFloat) -> some View {
        let isSelected = isSelected(width)
        let radius = InspectorMetrics.controlRadius - InspectorMetrics.controlInset
        return Button {
            onSelect(width)
        } label: {
            Circle()
                .fill(Color.primary.opacity(isSelected ? 0.9 : 0.5))
                .frame(width: dotSize(for: width), height: dotSize(for: width))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(isSelected ? InspectorControlPalette.segmentSelectedFill(for: colorScheme) : .clear)
                        .shadow(
                            color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0),
                            radius: 1,
                            y: 0.5
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(Int(width)) pt")
        .accessibilityLabel("Stroke width \(Int(width)) points")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
