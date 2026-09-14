import SwiftUI

/// An editor inspector section that remembers whether it was open (docs/14 UX-30).
///
/// The same control the studio already has, because the annotation inspector grew the same
/// way: eight groups, all open, all the time, so the two controls belonging to the object
/// the user just selected sat below five panels of global styling they set once a month.
///
/// Advanced global effects start closed; the sections that follow the selection do not.
struct EditorInspectorSection<Content: View>: View {
    let title: String
    /// Stored under this key, so the choice survives closing the window.
    let key: String
    var startsOpen = true
    @ViewBuilder var content: () -> Content

    @AppStorage private var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        key: String,
        startsOpen: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.key = key
        self.startsOpen = startsOpen
        self.content = content
        _isOpen = AppStorage(wrappedValue: startsOpen, "editor.inspector.\(key).isOpen")
    }

    var body: some View {
        Section {
            if isOpen {
                content()
            }
        } header: {
            header
        }
    }

    /// The whole header is the target, not just the chevron.
    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                isOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the \(title.lowercased()) controls")
        .accessibilityAddTraits(.isButton)
    }
}
