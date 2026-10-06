import AppKit
import ControlKit
import SwiftUI

/// Shared inspector chrome for the editor (docs/09 U1.5).
///
/// One control height, one radius, one label style and one section rhythm, so a column of
/// sliders, switches, menus and swatches reads as a single panel — the way Keynote's and
/// Xcode's inspectors do — rather than a grouped Form of mixed system widgets.
enum InspectorMetrics {
    static let sliderHeight: CGFloat = 32
    static let sliderRadius: CGFloat = KadrRadius.large
    /// Segmented controls, buttons, text fields.
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 7
    static let controlInset: CGFloat = 2
    static let tileRadius: CGFloat = KadrRadius.medium
    static let horizontalPadding: CGFloat = 14
    static let headerHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 10
    static let sectionBottomPadding: CGFloat = 14
    /// Fixed, so the values in a column of rows line up.
    static let labelColumnWidth: CGFloat = 78
}

enum InspectorControlPalette {
    static func trackFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
    }

    static func selectionFill(for colorScheme: ColorScheme) -> Color {
        // Increase Contrast takes the shared, stronger fill (docs/18 X-3).
        if KadrAccessibility.increaseContrast {
            return KadrFill.selected
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
    }

    /// The raised segment in a segmented track: a white pill in light mode, as AppKit draws it.
    static func segmentSelectedFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.white
    }

    static var hoverFill: Color {
        KadrFill.hover
    }

    static var border: Color {
        KadrFill.stroke
    }

    static let separator = Color(nsColor: .separatorColor).opacity(0.6)
}

extension Font {
    /// Section titles: quietly prominent, the way a macOS inspector names its groups.
    static let inspectorHeader = KadrType.font(KadrType.title, weight: .semibold)
    static let inspectorLabel = KadrType.font(KadrType.body)
    static let inspectorValue = KadrType.font(KadrType.body, weight: .medium)
    static let inspectorNumeric = KadrType.numeric(KadrType.body)
    static let inspectorNote = Font.system(size: KadrType.caption)
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

    /// A text field with the inspector's field chrome.
    func inspectorTextField() -> some View {
        textFieldStyle(.plain)
            .font(.inspectorValue)
            .padding(.horizontal, KadrSpace.medium)
            .inspectorField(height: InspectorMetrics.controlHeight, cornerRadius: InspectorMetrics.controlRadius)
    }

    /// A native pop-up inside an inspector row: label hidden, the row's full width.
    func inspectorMenuPicker() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
