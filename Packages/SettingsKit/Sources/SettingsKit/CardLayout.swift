import Foundation

/// Something a card can do (docs/09 U2.3).
///
/// Named separately from the after-capture actions because they answer different
/// questions: that one is "what happens automatically", this one is "what buttons are
/// there". They overlap in wording and not in meaning — a card can offer Delete, which is
/// not something anyone wants to happen automatically.
public enum CardAction: String, CaseIterable, Sendable, Codable {
    case copy
    case save
    /// Always asks where the file should land (CleanShot §6.2).
    case saveAs
    case annotate
    case pin
    case recognizeText
    case trim
    /// Open a recording in the studio, where its cuts, zooms and camera live (docs/09 U3).
    case studio
    case exportGIF
    case compress
    case share
    case delete

    public var title: String {
        switch self {
        case .copy: "Copy"
        case .save: "Save"
        case .saveAs: "Save As"
        case .annotate: "Annotate"
        case .pin: "Pin"
        case .recognizeText: "Copy Text"
        case .trim: "Trim"
        case .studio: "Studio"
        case .exportGIF: "Export GIF"
        case .compress: "Compress"
        case .share: "Share"
        case .delete: "Delete"
        }
    }

    public var systemImage: String {
        switch self {
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .annotate: "pencil.tip.crop.circle"
        case .pin: "pin"
        case .recognizeText: "text.viewfinder"
        case .trim: "scissors"
        case .studio: "wand.and.stars"
        case .exportGIF: "square.stack.3d.down.right"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .share: "square.and.arrow.up"
        case .delete: "trash"
        }
    }

    /// Whether this action means anything for a kind of capture.
    ///
    /// The same rule the settings matrix uses, for the same reason: a button that does
    /// nothing is worse than a missing one (docs/07 M8).
    public func applies(to kind: CaptureKind) -> Bool {
        switch kind {
        case .screenshot: self != .trim && self != .studio && self != .exportGIF
        case .recording: self != .annotate && self != .pin && self != .recognizeText
        }
    }
}

/// Where an action sits on a card (docs/09 U2.3).
///
/// Four corners and a centre column. The corners hold one action each and are always
/// visible; the column is ordered and appears when the card is expanded. That shape is not
/// arbitrary — a card is a thumbnail with room in its corners, and a list of buttons in the
/// middle of a picture is a list of buttons on top of the thing you are trying to look at.
public enum CardSlot: String, CaseIterable, Sendable, Codable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    /// The ordered row that appears when the card is expanded.
    case column

    public var title: String {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        case .column: "Action row"
        }
    }

    public var isCorner: Bool {
        self != .column
    }

    /// How many actions fit. A corner holds one; the row holds as many as the card is wide
    /// enough for, and the editor caps it rather than letting buttons fall off the edge.
    public var capacity: Int {
        isCorner ? 1 : CardLayout.columnCapacity
    }
}

/// Which action goes where on a card (docs/09 U2.3).
///
/// Ordinary value semantics on purpose: the settings pane edits a copy and commits it, so a
/// half-finished drag never reaches the cards on screen.
public struct CardLayout: Hashable, Sendable, Codable {
    /// The most actions a card's expanded row will hold before it runs out of width.
    ///
    /// Counted per kind of capture, not across the stored row. One layout serves both
    /// kinds and each card drops what does not apply, so a row holding every screenshot
    /// action *and* every recording action shows at most a few of each — capping the
    /// stored list would refuse arrangements that fit comfortably on both cards.
    public static let columnCapacity = 8

    /// One action per corner, or none.
    public var corners: [CardSlot: CardAction]
    /// The ordered action row.
    public var column: [CardAction]

    public init(corners: [CardSlot: CardAction] = [:], column: [CardAction] = []) {
        self.corners = corners.filter(\.key.isCorner)
        // Deduplicated rather than truncated: the cap is a per-kind display limit and is
        // applied where the row is read. What must never happen at any length is the same
        // action appearing twice.
        var seen: Set<CardAction> = []
        self.column = column.filter { seen.insert($0).inserted }
    }

    /// Kadr's own layout, and what the pane resets to.
    ///
    /// One layout serves both kinds and each card drops what does not apply, so the
    /// recording-only actions cost a screenshot nothing by being here. Which is why they
    /// are: Studio and Trim were both placeable and neither was placed, so a recording's
    /// card offered Copy, Save, Share and Delete and no way at all to edit the thing it
    /// was a card for.
    public static let standard = CardLayout(
        corners: [:],
        column: [.copy, .save, .annotate, .pin, .recognizeText, .studio, .trim, .share, .delete]
    )

    /// Every action currently placed anywhere.
    public var placedActions: Set<CardAction> {
        Set(corners.values).union(column)
    }

    /// Actions that mean something for this kind of capture and are not placed yet.
    public func availableActions(for kind: CaptureKind) -> [CardAction] {
        CardAction.allCases.filter { $0.applies(to: kind) && !placedActions.contains($0) }
    }

    /// The actions to draw in a slot, for a kind of capture.
    ///
    /// Filtered at read time rather than at edit time: one layout serves both kinds, so a
    /// user who places Trim sees it on recordings and not on screenshots, without having to
    /// keep two layouts in step.
    public func actions(in slot: CardSlot, for kind: CaptureKind) -> [CardAction] {
        switch slot {
        case .column:
            Array(column.filter { $0.applies(to: kind) }.prefix(Self.columnCapacity))
        default:
            corners[slot].flatMap { $0.applies(to: kind) ? [$0] : [] } ?? []
        }
    }

    // MARK: - Editing

    /// Puts an action in a slot, taking it out of wherever it was.
    ///
    /// An action appears once. Two Copy buttons on one card is not a layout somebody meant
    /// to build, and letting it happen turns every drag into a chance to make one.
    public mutating func place(_ action: CardAction, in slot: CardSlot, at index: Int? = nil) {
        remove(action)
        switch slot {
        case .column:
            let position = min(max(index ?? column.count, 0), column.count)
            // Refused only when it would overflow a card this action actually appears on.
            // Placing Trim cannot be blocked by a row full of screenshot actions, because
            // the two are never drawn together.
            guard fits(action) else { return }
            column.insert(action, at: position)
        default:
            // A corner holds one, so placing into a full corner displaces what was there
            // rather than refusing — the user is pointing at the corner they want.
            corners[slot] = action
        }
    }

    /// Whether adding an action leaves every card it appears on within its width.
    private func fits(_ action: CardAction) -> Bool {
        CaptureKind.allCases
            .filter { action.applies(to: $0) }
            .allSatisfy { actions(in: .column, for: $0).count < Self.columnCapacity }
    }

    /// Takes an action off the card entirely.
    public mutating func remove(_ action: CardAction) {
        column.removeAll { $0 == action }
        for (slot, placed) in corners where placed == action {
            corners.removeValue(forKey: slot)
        }
    }

    /// Moves an action within the row.
    public mutating func move(_ action: CardAction, toColumnIndex index: Int) {
        guard let current = column.firstIndex(of: action) else {
            place(action, in: .column, at: index)
            return
        }
        column.remove(at: current)
        column.insert(action, at: min(max(index, 0), column.count))
    }

    // MARK: - Storage

    private enum CodingKeys: String, CodingKey {
        case corners, column
    }

    /// Both fields default, so a layout written by a later Kadr with a sixth slot still
    /// opens — it simply arrives without that slot (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedCorners = try container.decodeIfPresent([String: CardAction].self, forKey: .corners) ?? [:]
        var corners: [CardSlot: CardAction] = [:]
        for (raw, action) in storedCorners {
            guard let slot = CardSlot(rawValue: raw), slot.isCorner else { continue }
            corners[slot] = action
        }
        try self.init(
            corners: corners,
            column: container.decodeIfPresent([CardAction].self, forKey: .column) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Keyed by the slot's raw string rather than by the enum, so the stored form is
        // readable in `defaults read` like everything else Kadr writes.
        try container.encode(
            Dictionary(uniqueKeysWithValues: corners.map { ($0.key.rawValue, $0.value) }),
            forKey: .corners
        )
        try container.encode(column, forKey: .column)
    }
}

/// Stored as JSON, unlike the flatter settings.
///
/// A layout is a structure rather than a value — a dictionary and an ordered list — and
/// flattening it into a dozen defaults keys to keep it readable would trade one legible
/// blob for twelve keys nobody could reassemble by hand anyway.
extension CardLayout: SettingValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> CardLayout? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CardLayout.self, from: data)
    }

    public func write(to defaults: UserDefaults, forKey key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
