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
    @State private var focusedSlot: CardSlot = .column
    @State private var selectedAction: CardAction?

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
            keyboardArrangement
            unplacedActions

            HStack {
                Button("Reset to the standard layout") {
                    settings.cardLayout = .standard
                    selectedAction = nil
                    announce("Reset to the standard layout.")
                }
                Spacer()
            }
        }
        .onChange(of: previewKind) { _, _ in
            selectedAction = nil
        }
        .onChange(of: focusedSlot) { _, _ in
            selectedAction = nil
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
            .background(
                selectedAction == action ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .draggable(action.rawValue) {
                Image(systemName: action.systemImage)
            }
            .help(action.title)
            .onTapGesture {
                selectedAction = action
                focusedSlot = slot
            }
            .contextMenu {
                Button("Remove") {
                    remove(action)
                }
            }
            .accessibilityLabel("\(action.title), \(slot.title)")
            .accessibilityAddTraits(selectedAction == action ? .isSelected : [])
    }

    // MARK: - Keyboard arrangement (docs/14 UX-12)

    private var keyboardArrangement: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard arrangement")
                .font(.headline)

            Picker("Slot", selection: $focusedSlot) {
                ForEach(CardSlot.allCases, id: \.self) { slot in
                    Text(slot.title).tag(slot)
                }
            }
            .pickerStyle(.menu)

            List(selection: $selectedAction) {
                ForEach(actionsInFocusedSlot, id: \.self) { action in
                    Label(action.title, systemImage: action.systemImage)
                        .tag(action)
                }
            }
            .frame(minHeight: 120)
            .accessibilityLabel("Actions in \(focusedSlot.title)")

            HStack(spacing: 8) {
                Menu("Add") {
                    ForEach(availableToAdd, id: \.self) { action in
                        Button(action.title) {
                            add(action, to: focusedSlot)
                        }
                    }
                }
                .disabled(availableToAdd.isEmpty)

                Button("Remove") { removeSelected() }
                    .disabled(selectedAction == nil || !isSelectedPlaced)

                Button("Move Earlier") { moveSelectedEarlier() }
                    .disabled(!canMoveSelectedEarlier)

                Button("Move Later") { moveSelectedLater() }
                    .disabled(!canMoveSelectedLater)

                Menu("Move to Slot") {
                    ForEach(CardSlot.allCases, id: \.self) { slot in
                        Button(slot.title) {
                            moveSelected(to: slot)
                        }
                        .disabled(selectedAction == nil)
                    }
                }
                .disabled(selectedAction == nil)
            }
        }
    }

    private var actionsInFocusedSlot: [CardAction] {
        layout.actions(in: focusedSlot, for: previewKind)
    }

    private var availableToAdd: [CardAction] {
        layout.availableActions(for: previewKind)
    }

    private var isSelectedPlaced: Bool {
        guard let selectedAction else { return false }
        return layout.placedActions.contains(selectedAction)
    }

    private var canMoveSelectedEarlier: Bool {
        guard let selectedAction, focusedSlot == .column else { return false }
        guard let index = layout.column.firstIndex(of: selectedAction) else { return false }
        return index > 0
    }

    private var canMoveSelectedLater: Bool {
        guard let selectedAction, focusedSlot == .column else { return false }
        guard let index = layout.column.firstIndex(of: selectedAction) else { return false }
        return index < layout.column.count - 1
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
            remove(action)
            return true
        }
    }

    // MARK: - Editing

    private func drop(_ items: [String], into slot: CardSlot) -> Bool {
        guard let action = items.compactMap(CardAction.init(rawValue:)).first else { return false }
        return place(action, in: slot)
    }

    private func add(_ action: CardAction, to slot: CardSlot) {
        guard place(action, in: slot) else { return }
        selectedAction = action
        focusedSlot = slot
    }

    private func remove(_ action: CardAction) {
        var updated = layout
        updated.remove(action)
        settings.cardLayout = updated
        if selectedAction == action {
            selectedAction = nil
        }
        announce("\(action.title) removed.")
    }

    private func removeSelected() {
        guard let selectedAction else { return }
        remove(selectedAction)
    }

    private func moveSelectedEarlier() {
        guard let selectedAction, let index = layout.column.firstIndex(of: selectedAction) else { return }
        var updated = layout
        updated.move(selectedAction, toColumnIndex: index - 1)
        settings.cardLayout = updated
        announce("\(selectedAction.title) moved earlier.")
    }

    private func moveSelectedLater() {
        guard let selectedAction, let index = layout.column.firstIndex(of: selectedAction) else { return }
        var updated = layout
        updated.move(selectedAction, toColumnIndex: index + 1)
        settings.cardLayout = updated
        announce("\(selectedAction.title) moved later.")
    }

    private func moveSelected(to slot: CardSlot) {
        guard let selectedAction else { return }
        guard place(selectedAction, in: slot) else { return }
        focusedSlot = slot
    }

    @discardableResult
    private func place(_ action: CardAction, in slot: CardSlot, at index: Int? = nil) -> Bool {
        var updated = layout
        let before = updated.placedActions
        updated.place(action, in: slot, at: index)
        guard updated.placedActions.contains(action) || before.contains(action) else {
            announce("No room for \(action.title) in \(slot.title).")
            return false
        }
        settings.cardLayout = updated
        announce("\(action.title) placed in \(slot.title).")
        return true
    }

    private func announce(_ message: String) {
        FeedbackAnnouncement.post(message)
    }
}
