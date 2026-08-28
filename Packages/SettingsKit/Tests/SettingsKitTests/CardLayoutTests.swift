import Foundation
import Testing
@testable import SettingsKit

/// Which buttons a card offers, and where (docs/09 U2.3).
@Suite("Card layout")
struct CardLayoutTests {
    // MARK: - The default

    /// The feature is opt-in by being invisible: somebody who never opens the editor sees
    /// the row the cards have always had.
    @Test("The standard layout is the row the cards already had")
    func standardIsTheOldRow() {
        let layout = CardLayout.standard
        #expect(layout.column.first == .copy)
        #expect(layout.column.contains(.delete))
        #expect(layout.corners.isEmpty)
    }

    // MARK: - Placement

    @Test("Placing an action puts it where it was asked to go")
    func placing() {
        var layout = CardLayout()
        layout.place(.copy, in: .topLeading)
        #expect(layout.actions(in: .topLeading, for: .screenshot) == [.copy])
    }

    /// Two Copy buttons on one card is not a layout anybody meant to build, and allowing
    /// it turns every drag into a chance to make one.
    @Test("An action appears exactly once")
    func actionsAreUnique() {
        var layout = CardLayout()
        layout.place(.copy, in: .topLeading)
        layout.place(.copy, in: .column)

        #expect(layout.actions(in: .topLeading, for: .screenshot).isEmpty)
        #expect(layout.column == [.copy])
    }

    @Test("A corner holds one action, and placing into a full one displaces it")
    func cornerCapacity() {
        var layout = CardLayout()
        layout.place(.copy, in: .topLeading)
        layout.place(.save, in: .topLeading)

        #expect(layout.actions(in: .topLeading, for: .screenshot) == [.save])
        #expect(!layout.placedActions.contains(.copy), "the displaced action leaves the card")
    }

    @Test("The row holds a bounded number of actions")
    func columnCapacity() {
        var layout = CardLayout()
        for action in CardAction.allCases {
            layout.place(action, in: .column)
        }
        #expect(layout.column.count <= CardLayout.columnCapacity)
    }

    @Test("An action can be placed at a position in the row")
    func placingAtAnIndex() {
        var layout = CardLayout(column: [.copy, .save])
        layout.place(.delete, in: .column, at: 1)
        #expect(layout.column == [.copy, .delete, .save])
    }

    @Test("Moving reorders rather than duplicating")
    func moving() {
        var layout = CardLayout(column: [.copy, .save, .delete])
        layout.move(.delete, toColumnIndex: 0)
        #expect(layout.column == [.delete, .copy, .save])
    }

    @Test("Moving something that is not on the card places it")
    func movingSomethingUnplaced() {
        var layout = CardLayout(column: [.copy])
        layout.move(.pin, toColumnIndex: 0)
        #expect(layout.column == [.pin, .copy])
    }

    @Test("Removing takes an action off entirely")
    func removing() {
        var layout = CardLayout(corners: [.topLeading: .delete], column: [.copy])
        layout.remove(.delete)
        layout.remove(.copy)
        #expect(layout.placedActions.isEmpty)
    }

    // MARK: - Applicability

    /// One layout serves both kinds, filtered at read time — so placing Trim shows it on
    /// recordings and hides it on screenshots, with no second layout to keep in step.
    @Test("A layout is filtered by what the capture is")
    func filteredByKind() {
        var layout = CardLayout()
        layout.place(.trim, in: .column)
        layout.place(.annotate, in: .column)

        #expect(layout.actions(in: .column, for: .recording) == [.trim])
        #expect(layout.actions(in: .column, for: .screenshot) == [.annotate])
    }

    @Test("A corner action that does not apply is simply not drawn")
    func inapplicableCorner() {
        var layout = CardLayout()
        layout.place(.pin, in: .topTrailing)

        #expect(layout.actions(in: .topTrailing, for: .screenshot) == [.pin])
        #expect(layout.actions(in: .topTrailing, for: .recording).isEmpty)
    }

    @Test("Every action applies to at least one kind")
    func everyActionIsUsefulSomewhere() {
        for action in CardAction.allCases {
            #expect(
                CaptureKind.allCases.contains { action.applies(to: $0) },
                "\(action.title) applies to nothing"
            )
        }
    }

    @Test("Trim and GIF are for recordings; annotate, pin and OCR are not")
    func applicability() {
        #expect(!CardAction.trim.applies(to: .screenshot))
        #expect(!CardAction.exportGIF.applies(to: .screenshot))
        #expect(!CardAction.annotate.applies(to: .recording))
        #expect(!CardAction.pin.applies(to: .recording))
        #expect(!CardAction.recognizeText.applies(to: .recording))
        #expect(CardAction.copy.applies(to: .screenshot))
        #expect(CardAction.copy.applies(to: .recording))
    }

    @Test("The palette offers what is applicable and not yet placed")
    func availableActions() {
        var layout = CardLayout()
        layout.place(.copy, in: .column)

        let available = layout.availableActions(for: .screenshot)
        #expect(!available.contains(.copy), "already placed")
        #expect(!available.contains(.trim), "not applicable to a screenshot")
        #expect(available.contains(.save))
    }

    @Test("Every action has a distinct title and symbol")
    func titlesAndSymbols() {
        #expect(Set(CardAction.allCases.map(\.title)).count == CardAction.allCases.count)
        #expect(Set(CardAction.allCases.map(\.systemImage)).count == CardAction.allCases.count)
    }

    // MARK: - Storage

    private func throwawayDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("A layout round-trips through the defaults store")
    func roundTrips() {
        let store = throwawayDefaults()
        var layout = CardLayout()
        layout.place(.delete, in: .bottomTrailing)
        layout.place(.copy, in: .column)
        layout.place(.save, in: .column)

        layout.write(to: store, forKey: "test.layout")
        #expect(CardLayout.read(from: store, forKey: "test.layout") == layout)
    }

    @Test("Nothing stored reads as nothing, so the default applies")
    func nothingStored() {
        #expect(CardLayout.read(from: throwawayDefaults(), forKey: "test.absent") == nil)
    }

    @Test("A corrupt layout is refused rather than half-read")
    func corruptLayout() {
        let store = throwawayDefaults()
        store.set(Data("not json".utf8), forKey: "test.layout")
        #expect(CardLayout.read(from: store, forKey: "test.layout") == nil)
    }

    /// A layout written by a later Kadr with a sixth slot still opens — it simply arrives
    /// without that slot (docs/08 §2.6).
    @Test("An unknown slot is ignored, not fatal")
    func unknownSlotIsIgnored() throws {
        let json = """
        {"corners": {"topLeading": "copy", "sideways": "save"}, "column": ["delete"]}
        """
        let layout = try JSONDecoder().decode(CardLayout.self, from: Data(json.utf8))
        #expect(layout.corners[.topLeading] == .copy)
        #expect(layout.column == [.delete])
    }

    @Test("A layout with nothing in it at all decodes to an empty card")
    func emptyObject() throws {
        let layout = try JSONDecoder().decode(CardLayout.self, from: Data("{}".utf8))
        #expect(layout.placedActions.isEmpty)
    }

    /// The column slot cannot be stored as a corner, whatever a file claims.
    @Test("The row cannot sneak into the corners")
    func columnIsNotACorner() throws {
        let json = #"{"corners": {"column": "copy"}, "column": []}"#
        let layout = try JSONDecoder().decode(CardLayout.self, from: Data(json.utf8))
        #expect(layout.corners.isEmpty)
    }
}
