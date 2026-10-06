import ControlKit
import SwiftUI

/// A titled inspector section that is always open — the context the user is working in.
struct InspectorGroup<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.inspectorHeader)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .frame(height: InspectorMetrics.headerHeight)

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                content()
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.bottom, InspectorMetrics.sectionBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) { InspectorDivider() }
    }
}

extension InspectorGroup where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Hairline between sections, inset to the content.
struct InspectorDivider: View {
    var body: some View {
        Rectangle()
            .fill(InspectorControlPalette.separator)
            .frame(height: 0.5)
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
    }
}

/// A label column and a value, so a stack of rows lines its values up.
struct InspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: InspectorMetrics.labelColumnWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: InspectorMetrics.controlHeight)
    }
}

/// A label above content that needs the full width — swatches, grids.
struct InspectorStackedRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A statement and a switch at the trailing edge.
struct InspectorToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.inspectorLabel)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(minHeight: InspectorMetrics.controlHeight)
    }
}

/// A statement and a colour well at the trailing edge.
struct InspectorColorRow: View {
    let title: String
    @Binding var selection: Color
    var supportsOpacity = true

    init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.title = title
        _selection = selection
        self.supportsOpacity = supportsOpacity
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.inspectorLabel)
                .lineLimit(1)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            ColorPicker(title, selection: $selection, supportsOpacity: supportsOpacity)
                .labelsHidden()
        }
        .frame(minHeight: InspectorMetrics.controlHeight)
    }
}

/// The inspector's one segmented control: a neutral track with a raised selected segment.
///
/// Drawn rather than `.pickerStyle(.segmented)`, whose height, font and inactive-window
/// dimming did not match the sliders and fields beside it.
struct InspectorSegmented<Option: Hashable, Label: View>: View {
    let options: [Option]
    @Binding var selection: Option
    let accessibilityTitle: (Option) -> String
    @ViewBuilder let label: (Option) -> Label

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered: Option?

    init(
        options: [Option],
        selection: Binding<Option>,
        accessibilityTitle: @escaping (Option) -> String,
        @ViewBuilder label: @escaping (Option) -> Label
    ) {
        self.options = options
        _selection = selection
        self.accessibilityTitle = accessibilityTitle
        self.label = label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.controlRadius, style: .continuous)
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(InspectorMetrics.controlInset)
        .frame(height: InspectorMetrics.controlHeight)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .overlay(shape.strokeBorder(InspectorControlPalette.border, lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        let radius = InspectorMetrics.controlRadius - InspectorMetrics.controlInset
        return Button {
            selection = option
        } label: {
            label(option)
                .font(.inspectorValue)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(segmentFill(isSelected: isSelected, isHovered: hovered == option))
                .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0), radius: 1, y: 0.5)
        }
        .onHover { hovering in
            if hovering {
                hovered = option
            } else if hovered == option {
                hovered = nil
            }
        }
        .accessibilityLabel(accessibilityTitle(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func segmentFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return InspectorControlPalette.segmentSelectedFill(for: colorScheme)
        }
        return isHovered && isEnabled ? InspectorControlPalette.hoverFill : .clear
    }
}

extension InspectorSegmented where Label == Text {
    init(_ options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.init(options: options, selection: selection, accessibilityTitle: title) { option in
            Text(title(option))
        }
    }
}

/// A quiet bordered button, or the accent-filled commit button.
struct InspectorButtonStyle: ButtonStyle {
    var isProminent = false
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        InspectorButtonBody(configuration: configuration, isProminent: isProminent, fillsWidth: fillsWidth)
    }
}

private struct InspectorButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isProminent: Bool
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.controlRadius, style: .continuous)
        configuration.label
            .font(.inspectorValue)
            .lineLimit(1)
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, KadrSpace.large)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: InspectorMetrics.controlHeight)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(isProminent ? Color.clear : InspectorControlPalette.border, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if isProminent {
            return Color.accentColor.opacity(isHovering && isEnabled ? 0.88 : 1)
        }
        return isHovering && isEnabled
            ? InspectorControlPalette.selectionFill(for: colorScheme)
            : InspectorControlPalette.trackFill(for: colorScheme)
    }
}

/// A small glyph action for a section header: reset, duplicate, delete.
struct InspectorIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: KadrType.caption, weight: .semibold))
                .foregroundStyle(isHovering && isEnabled ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isHovering && isEnabled ? InspectorControlPalette.hoverFill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Secondary explanation under a control.
struct InspectorNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.inspectorNote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a pane says when it has nothing to show, instead of being blank.
struct InspectorEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.inspectorValue)
            Text(message)
                .font(.inspectorNote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}
