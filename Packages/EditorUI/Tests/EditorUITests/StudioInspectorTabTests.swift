import Testing
@testable import EditorUI

/// Which inspector pane a selection brings forward (docs/09 U3.3).
@Suite("Studio inspector panes")
struct StudioInspectorTabTests {
    @Test("Selecting a zoom reveals the pane that edits it")
    func zoomRevealsClipPane() {
        #expect(StudioInspectorTab.revealing(zoom: true, clip: false) == .clip)
    }

    @Test("Selecting a clip reveals the same pane")
    func clipRevealsClipPane() {
        #expect(StudioInspectorTab.revealing(zoom: false, clip: true) == .clip)
    }

    @Test("Clearing a selection leaves the panes alone")
    func clearingStaysPut() {
        // Escape deselects. Throwing the user back to another pane for that would mean
        // losing your place in the inspector every time you dismissed something.
        #expect(StudioInspectorTab.revealing(zoom: false, clip: false) == nil)
    }

    @Test("Every pane has a title and a distinct identity")
    func panesAreWellFormed() {
        let tabs = StudioInspectorTab.allCases
        #expect(tabs.count == 4)
        #expect(Set(tabs.map(\.id)).count == tabs.count)
        #expect(tabs.allSatisfy { !$0.title.isEmpty })
        // VoiceOver reads the longer name: "Frame" alone could be a rectangle or a video frame.
        #expect(tabs.allSatisfy { $0.accessibilityLabel != $0.title })
        #expect(StudioInspectorTab(rawValue: "clip") == .clip)
    }
}
