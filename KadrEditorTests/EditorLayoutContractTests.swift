import CoreGraphics
import EditorUI
import Testing

/// The editor's window floors match the agent's layout contract (docs/14 UX-05).
///
/// The editor cannot import `UXLayoutContract`, which lives in the agent, so the numbers
/// are pinned here instead; a change to one side fails until the other follows.
@Suite("Editor layout contract")
struct EditorLayoutContractTests {
    @Test("Editor and studio minimums match the contract and fit the smallest display")
    func minimums() {
        #expect(EditorWindowGeometry.minSize == CGSize(width: 760, height: 580))
        #expect(EditorWindowGeometry.studioMinSize == CGSize(width: 820, height: 520))
        let smallest = CGSize(width: 1024, height: 640)
        for size in [EditorWindowGeometry.minSize, EditorWindowGeometry.studioMinSize] {
            #expect(size.width <= smallest.width && size.height <= smallest.height)
        }
    }
}
