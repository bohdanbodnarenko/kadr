import SwiftUI

/// The editor's standard numeric control (docs/09 U1.5).
///
/// The whole field is the track: the label sits *inside* it, and dragging anywhere on the
/// row scrubs. That is worth the custom control because an inspector is a column of these,
/// and a stock slider spends half its width on a thumb the user aims at — while the label
/// beside it, which is the part they read, is not draggable at all. Here the thing you read
/// and the thing you drag are the same object.
///
/// Clicking it turns it into a text field, so an exact value can be typed with its unit:
/// "45%", "12px", "30deg", "1.5×". Arrow keys step by one of whatever the field shows.
struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: InspectorValueFormat = .percent
    /// Called when a drag ends, so a caller can settle an expensive preview (docs/09 U1.3).
    var onEditingEnded: () -> Void = {}

    @State private var isEditing = false
    @State private var draftText = ""
    @State private var dragStartValue: Double?
    @FocusState private var isFieldFocused: Bool

    private static let height: CGFloat = 24
    private static let cornerRadius: CGFloat = 5

    var body: some View {
        ZStack {
            if isEditing {
                field
            } else {
                track
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format.string(for: value))
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1)
        }
    }

    // MARK: - Scrubbing

    private var track: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: geometry.size.width * fraction)
                HStack {
                    Text(title)
                    Spacer()
                    Text(format.string(for: value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 7)
            }
            .contentShape(Rectangle())
            .gesture(scrub(width: geometry.size.width))
            .onTapGesture(count: 2) { beginEditing() }
        }
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// Relative rather than absolute: dragging moves the value by how far the pointer
    /// travelled, so grabbing the row does not jump the value to wherever the click landed.
    /// Absolute would make the whole-row track a liability — every click would be a change.
    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStartValue ?? value
                if dragStartValue == nil {
                    dragStartValue = start
                }
                guard width > 0 else { return }
                let span = range.upperBound - range.lowerBound
                let moved = drag.translation.width / width * span
                value = min(max(start + moved, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                dragStartValue = nil
                onEditingEnded()
            }
    }

    private func step(_ steps: Int) {
        value = min(max(format.stepped(value, by: steps), range.lowerBound), range.upperBound)
        onEditingEnded()
    }

    // MARK: - Typing

    private var field: some View {
        TextField(title, text: $draftText)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .focused($isFieldFocused)
            .onSubmit { commitEditing() }
            .onChange(of: isFieldFocused) { _, focused in
                if !focused {
                    commitEditing()
                }
            }
            .onExitCommand { isEditing = false }
    }

    private func beginEditing() {
        draftText = format.string(for: value)
        isEditing = true
        isFieldFocused = true
    }

    private func commitEditing() {
        defer {
            isEditing = false
            onEditingEnded()
        }
        // An unparseable entry leaves the value alone rather than zeroing it: a typo
        // should cost a retype, not the setting.
        guard let parsed = format.value(from: draftText) else { return }
        value = min(max(parsed, range.lowerBound), range.upperBound)
    }
}
