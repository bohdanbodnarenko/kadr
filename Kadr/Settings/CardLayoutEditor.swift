import SettingsKit
import SwiftUI
import UniformTypeIdentifiers

/// Arranging a card's buttons by dragging them onto a picture of one (docs/09 U2.3).
///
/// A mock card rather than a list of checkboxes, because the question being answered is
/// spatial: "is Delete somewhere I will hit it by accident" is not a question a list can
/// show you. The mock is drawn from the same layout the real cards read, so what is
/// arranged here is what appears.
struct CardLayoutEditor: View {
    @Bindable var settings: AppSettings

    /// Which kind of capture the mock is showing, since one layout serves both and the
    /// actions that apply differ.
    @State private var previewKind: CaptureKind = .screenshot
    @State private var dragging: CardAction?

    private var layout: CardLayout {
        settings.cardLayout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Preview", selection: $previewKind) {
                ForEach(CaptureKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            mockCard
            unplacedActions

            HStack {
                Button("Reset to the standard layout") {
                    settings.cardLayout = .standard
                }
                Spacer()
            }
        }
    }

    // MARK: - The mock

    private var mockCard: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 90)
                    .overlay(
                        Text("Thumbnail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )

                VStack {
                    HStack {
                        cornerWell(.topLeading)
                        Spacer()
                        cornerWell(.topTrailing)
                    }
                    Spacer()
                    HStack {
                        cornerWell(.bottomLeading)
                        Spacer()
                        cornerWell(.bottomTrailing)
                    }
                }
                .padding(6)
            }
            columnWell
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private func cornerWell(_ slot: CardSlot) -> some View {
        let placed = layout.actions(in: slot, for: previewKind).first
        return Group {
            if let placed {
                chip(placed, in: slot)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(dash: [3, 3]))
                    .frame(width: 26, height: 26)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: slot)
        }
        .help(slot.title)
    }

    private var columnWell: some View {
        HStack(spacing: 4) {
            ForEach(layout.actions(in: .column, for: previewKind), id: \.self) { action in
                chip(action, in: .column)
            }
            if layout.column.count < CardLayout.columnCapacity {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(dash: [3, 3]))
                    .frame(width: 26, height: 26)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: .column)
        }
        .help(CardSlot.column.title)
    }

    /// One placed action. Dragging it moves it; the ⨉ takes it off the card.
    private func chip(_ action: CardAction, in slot: CardSlot) -> some View {
        Image(systemName: action.systemImage)
            .frame(width: 26, height: 26)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .draggable(action.rawValue) {
                Image(systemName: action.systemImage)
            }
            .help(action.title)
            .contextMenu {
                Button("Remove") {
                    var updated = layout
                    updated.remove(action)
                    settings.cardLayout = updated
                }
            }
            .accessibilityLabel("\(action.title), \(slot.title)")
    }

    // MARK: - The palette

    private var unplacedActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag onto the card")
                .font(.caption)
                .foregroundStyle(.secondary)

            let available = layout.availableActions(for: previewKind)
            if available.isEmpty {
                Text("Every action is already on the card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(available, id: \.self) { action in
                        Image(systemName: action.systemImage)
                            .frame(width: 26, height: 26)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .draggable(action.rawValue) {
                                Image(systemName: action.systemImage)
                            }
                            .help(action.title)
                            .accessibilityLabel(action.title)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        // Dropping onto the palette takes an action off the card, which is the gesture
        // people try before they find the context menu.
        .dropDestination(for: String.self) { items, _ in
            guard let action = items.compactMap(CardAction.init(rawValue:)).first else { return false }
            var updated = layout
            updated.remove(action)
            settings.cardLayout = updated
            return true
        }
    }

    private func drop(_ items: [String], into slot: CardSlot) -> Bool {
        guard let action = items.compactMap(CardAction.init(rawValue:)).first else { return false }
        var updated = layout
        updated.place(action, in: slot)
        settings.cardLayout = updated
        return true
    }
}
