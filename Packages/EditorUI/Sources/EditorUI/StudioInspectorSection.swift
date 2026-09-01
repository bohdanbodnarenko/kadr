import SwiftUI

/// A collapsible inspector section that remembers whether it was open (docs/08 §2).
///
/// The studio's inspector was seven `Section`s, all open, all the time — a column the user
/// scrolled past to reach the two controls they were actually using. Every section is a
/// distinct job (the shape of the output, what the camera does, what is drawn on top), and
/// most of them are set once and left alone, so the ones that matter right now should be the
/// ones taking up room.
///
/// Open state is per-section and persisted, because a panel that forgets what you folded is
/// a panel you fold every time you open a recording.
struct StudioInspectorSection<Content: View>: View {
    let title: String
    /// Stored under this key, so the choice survives closing the window.
    let key: String
    /// Sections nobody has touched start open when they are the common ones and closed when
    /// they are not — a first run should show the controls people reach for, not everything.
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
        _isOpen = AppStorage(wrappedValue: startsOpen, "studio.inspector.\(key).isOpen")
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
    ///
    /// A disclosure triangle alone is a six-point target for a row that is two hundred wide,
    /// and the row is what the pointer is already over.
    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                isOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
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
