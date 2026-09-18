import SwiftUI

/// One page of the island's first-open tour (docs/03 §1.4).
///
/// Built from the same tables the island and the hotkeys use — the mode letters, the tool
/// letters and the user's actual global shortcuts — so the tour cannot teach a key the app
/// does not answer to.
struct IslandTourStep: Identifiable {
    struct Row: Identifiable {
        let key: String
        let text: String

        var id: String {
            key + text
        }
    }

    let id: Int
    let title: String
    let rows: [Row]
    let footnote: String?
    var offersShortcutSettings = false

    @MainActor
    static var all: [IslandTourStep] {
        [modes, more, anywhere]
    }

    private static func row(_ mode: AllInOneMode) -> Row {
        Row(key: mode.keyCaption, text: mode.title)
    }

    private static var modes: IslandTourStep {
        IslandTourStep(
            id: 0,
            title: "Press a letter to capture",
            rows: [.area, .window, .screen, .record].map(row),
            footnote: "Return repeats your last mode. Esc closes the island."
        )
    }

    private static var more: IslandTourStep {
        let tools: [AllInOneTool] = [.previousArea, .selfTimer, .freezeScreen, .pinClipboard]
        return IslandTourStep(
            id: 1,
            title: "More modes, and the Tools menu",
            rows: [.gif, .scrolling, .ocr, .color].map(row)
                + tools.map { Row(key: String($0.shortcut).uppercased(), text: $0.title) },
            footnote: "Hover any button to see its key."
        )
    }

    @MainActor
    private static var anywhere: IslandTourStep {
        let commands: [(CaptureCommand, String)] = [
            (.allInOne, "Open or close this island"),
            (.captureArea, "Capture an area"),
            (.captureFullscreen, "Capture the screen"),
            (.recordSetup, "Start a recording"),
            (.stopRecording, "Stop the recording")
        ]
        let rows = commands.compactMap { command, text in
            CoachMarks.shortcutText(for: command).map { Row(key: $0, text: text) }
        }
        return IslandTourStep(
            id: 2,
            title: "From any app",
            rows: rows,
            footnote: rows.isEmpty
                ? "No global shortcuts are set. Add your own in Settings."
                : "Every other command can have a shortcut too.",
            offersShortcutSettings: true
        )
    }
}

/// Where the tour is. Observed by the one view that stays up for the whole tour.
@MainActor
@Observable
final class IslandTourModel {
    let steps: [IslandTourStep]
    private(set) var index = 0

    init(steps: [IslandTourStep]) {
        self.steps = steps
    }

    var isLast: Bool {
        index >= steps.count - 1
    }

    /// Moves by one page; returns false when there is no page to move to.
    @discardableResult
    func move(by delta: Int) -> Bool {
        let next = index + delta
        guard steps.indices.contains(next) else { return false }
        withAnimation(AccessibilityChrome.animation(.smooth(duration: 0.28))) {
            index = next
        }
        return true
    }
}

/// The tour's card: a page of keys, where you are, and the ways on or out.
///
/// One view for the whole tour, never replaced. Every page is laid out at once in a
/// `ZStack`, so the card — and the popover around it — take the tallest page's size once
/// and keep it; only the page on show is visible and clickable. Swapping the popover's
/// root view per page instead made AppKit animate the popover's size while SwiftUI
/// snapped the content, which is what looked broken.
struct IslandTourView: View {
    let model: IslandTourModel
    let next: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { position, step in
                    let isCurrent = position == model.index
                    page(step)
                        .opacity(isCurrent ? 1 : 0)
                        .offset(x: offset(for: position))
                        .allowsHitTesting(isCurrent)
                        .accessibilityHidden(!isCurrent)
                }
            }
            .clipped()
            controls
        }
        .padding(16)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip \(model.index + 1) of \(model.steps.count)")
    }

    /// Pages before the current one wait to the left, pages after it to the right, so a
    /// move reads as a slide in the direction of the button that was pressed.
    private func offset(for position: Int) -> CGFloat {
        guard !AccessibilityChrome.reduceMotion else { return 0 }
        if position == model.index {
            return 0
        }
        return position < model.index ? -18 : 18
    }

    private func page(_ step: IslandTourStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.headline)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(step.rows) { row in
                    CoachRow(key: row.key, text: row.text)
                }
            }
            if let footnote = step.footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The close button sits over the pages rather than in each, so it never fades.
        .padding(.trailing, 22)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            progress
            Spacer()
            if model.steps[model.index].offersShortcutSettings {
                Button("Shortcuts…", action: openSettings)
                    .transition(.opacity)
            }
            if model.index > 0 {
                Button("Back") { model.move(by: -1) }
                    .transition(.opacity)
            }
            Button(model.isLast ? "Done" : "Next", action: next)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< model.steps.count, id: \.self) { page in
                Capsule()
                    .fill(page == model.index ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: page == model.index ? 14 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
