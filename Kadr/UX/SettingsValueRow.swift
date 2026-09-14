import SwiftUI

/// Agent-local numeric setting: label, system slider, persistent typed value (docs/14 UX-11).
///
/// Must not import EditorUI. Arrow keys adjust by one displayed unit. Changing the value
/// never shifts adjacent layout because the field has a fixed width.
struct SettingsValueRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: Unit = .plain
    var decimals: Int = 0

    enum Unit: Equatable, Sendable {
        case percent
        case points
        case wordsPerMinute
        case plain

        var suffix: String {
            switch self {
            case .percent: "%"
            case .points: " pt"
            case .wordsPerMinute: " wpm"
            case .plain: ""
            }
        }
    }

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue(displayed)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: nudge(1)
                        case .decrement: nudge(-1)
                        @unknown default: break
                        }
                    }
                TextField("", text: $draft, onCommit: commit)
                    .focused($isEditing)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(title) value")
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: value) { _, _ in
            if !isEditing {
                syncDraft()
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                commit()
            }
        }
        .onExitCommand {
            isEditing = false
        }
    }

    private var displayed: String {
        format(value)
    }

    private func nudge(_ steps: Double) {
        let next = min(max(value + steps * step, range.lowerBound), range.upperBound)
        value = next
    }

    private func syncDraft() {
        draft = format(value)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: unit.suffix, with: "")
            .replacingOccurrences(of: ",", with: ".")
        if let parsed = Double(trimmed) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        syncDraft()
    }

    private func format(_ number: Double) -> String {
        if decimals == 0 {
            return "\(Int(number.rounded()))\(unit.suffix)"
        }
        return String(format: "%.\(decimals)f%@", number, unit.suffix)
    }
}
