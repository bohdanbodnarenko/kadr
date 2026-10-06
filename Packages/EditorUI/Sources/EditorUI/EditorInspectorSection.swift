import ControlKit
import SwiftUI

/// A collapsible inspector section that remembers whether it was open (docs/14 UX-30).
///
/// Advanced global effects start closed; the choice is persisted per section, because a
/// panel that forgets what you folded is a panel you fold every time.
///
/// An effect that can be off carries its switch in the header — the way Keynote puts one
/// beside "Shadow" — so whether it is on reads with the section folded, turning it on opens
/// the section to its controls, and turning it off folds them away.
struct EditorInspectorSection<Content: View, Accessory: View>: View {
    let title: String
    /// Stored under this key, so the choice survives closing the window.
    let key: String
    var isEnabled: Binding<Bool>?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @AppStorage private var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHeaderHovering = false

    init(
        title: String,
        key: String,
        startsOpen: Bool = true,
        isEnabled: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.key = key
        self.isEnabled = isEnabled
        self.accessory = accessory
        self.content = content
        _isOpen = AppStorage(wrappedValue: startsOpen, "editor.inspector.\(key).isOpen")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Built only while open: a folded effect costs nothing when the document changes.
            if isOpen {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    content()
                }
                .disabled(isEnabled?.wrappedValue == false)
                .opacity(isEnabled?.wrappedValue == false ? 0.45 : 1)
                .padding(.horizontal, InspectorMetrics.horizontalPadding)
                .padding(.bottom, InspectorMetrics.sectionBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { InspectorDivider() }
    }

    /// The whole title is the target, not just the chevron.
    private var header: some View {
        HStack(spacing: 4) {
            Button(action: toggleOpen) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.inspectorHeader)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(Text("Shows or hides the \(title.lowercased()) controls", bundle: .module))
            .accessibilityAddTraits(.isHeader)

            accessory()

            if let isEnabled {
                Toggle(title, isOn: Binding(
                    get: { isEnabled.wrappedValue },
                    set: { setEnabled($0, binding: isEnabled) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.leading, KadrSpace.xs)
            }

            Button(action: toggleOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: KadrType.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .frame(height: InspectorMetrics.headerHeight)
        .background(isHeaderHovering ? InspectorControlPalette.hoverFill.opacity(0.5) : Color.clear)
        .onHover { isHeaderHovering = $0 }
    }

    private var motion: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    private func toggleOpen() {
        withAnimation(motion) {
            isOpen.toggle()
        }
    }

    private func setEnabled(_ enabled: Bool, binding: Binding<Bool>) {
        binding.wrappedValue = enabled
        guard enabled != isOpen else { return }
        withAnimation(motion) {
            isOpen = enabled
        }
    }
}

extension EditorInspectorSection where Accessory == EmptyView {
    init(
        title: String,
        key: String,
        startsOpen: Bool = true,
        isEnabled: Binding<Bool>? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            key: key,
            startsOpen: startsOpen,
            isEnabled: isEnabled,
            accessory: { EmptyView() },
            content: content
        )
    }
}
