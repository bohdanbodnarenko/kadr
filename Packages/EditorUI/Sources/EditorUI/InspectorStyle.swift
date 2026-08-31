import SwiftUI

/// Shared inspector chrome for the editor (docs/09 U1.5).
///
/// One height, one radius, one track fill, so a column of sliders, fields and pickers
/// reads as a single control rather than a mixed bag of system widgets.
enum InspectorMetrics {
    static let sliderHeight: CGFloat = 32
    /// Wide enough for "32 px", "100%", and signed camera values like "+18°" on one line.
    static let sliderValueWidth: CGFloat = 80
    static let sliderRadius: CGFloat = 8
}

enum InspectorControlPalette {
    static func trackFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
    }

    static func selectionFill(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
    }
}

extension Font {
    static let inspectorValue = Font.system(size: 11, weight: .medium)
    static let inspectorNumeric = Font.system(size: 11, weight: .medium).monospacedDigit()
}

private struct InspectorFieldChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat?
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fill: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035)
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
}

extension View {
    func inspectorField(
        height: CGFloat? = InspectorMetrics.sliderHeight,
        cornerRadius: CGFloat = InspectorMetrics.sliderRadius
    ) -> some View {
        modifier(InspectorFieldChrome(height: height, cornerRadius: cornerRadius))
    }

    /// macOS 15's column-resize pointer; a no-op on 14, where the drag still works.
    @ViewBuilder
    func inspectorColumnResizePointer(enabled: Bool) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(enabled ? PointerStyle.columnResize : nil)
        } else {
            self
        }
    }
}
