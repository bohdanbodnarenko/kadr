import Foundation
import Testing
@testable import EditorUI

@Suite("Editor save targets (T-ED-1)")
struct EditorSaveTargetsTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let document: String
        let keepOriginal: Bool
        let writesProject: Bool
        let existing: Set<String>
        let flattened: String
        let project: String?
        var testDescription: String {
            label
        }
    }

    static let dir = "/Users/me/Shots/"

    static let cases: [Case] = [
        Case(
            label: "capture, keep original, sidecar",
            document: "X.png",
            keepOriginal: true,
            writesProject: true,
            existing: [],
            flattened: "X annotated.png",
            project: "X annotated.kadr"
        ),
        Case(
            label: "capture, keep original, no sidecar",
            document: "X.png",
            keepOriginal: true,
            writesProject: false,
            existing: [],
            flattened: "X annotated.png",
            project: nil
        ),
        Case(
            label: "capture, overwrite keeps the format",
            document: "X.jpg",
            keepOriginal: false,
            writesProject: true,
            existing: [],
            flattened: "X.jpg",
            project: "X.kadr"
        ),
        Case(
            label: "the annotated pair saves in place, not as annotated annotated",
            document: "X annotated.kadr",
            keepOriginal: true,
            writesProject: false,
            existing: ["X annotated.png"],
            flattened: "X annotated.png",
            project: "X annotated.kadr"
        ),
        Case(
            label: "an agent project, overwrite: sibling image and project in place",
            document: "X.kadr",
            keepOriginal: false,
            writesProject: false,
            existing: ["X.heic"],
            flattened: "X.heic",
            project: "X.kadr"
        ),
        Case(
            label: "an agent project, keep original: the capture is left alone",
            document: "X.kadr",
            keepOriginal: true,
            writesProject: true,
            existing: ["X.png"],
            flattened: "X annotated.png",
            project: "X annotated.kadr"
        ),
        Case(
            label: "a project with no image beside it gets a PNG",
            document: "Plan.kadr",
            keepOriginal: false,
            writesProject: false,
            existing: [],
            flattened: "Plan.png",
            project: "Plan.kadr"
        )
    ]

    @Test("⌘S writes one stable pair", arguments: cases)
    func plan(_ testCase: Case) {
        let existing = Set(testCase.existing.map { Self.dir + $0 })
        let targets = EditorSaveTargets.plan(
            document: URL(fileURLWithPath: Self.dir + testCase.document),
            keepOriginal: testCase.keepOriginal,
            writesProject: testCase.writesProject,
            fileExists: { existing.contains($0.path) }
        )
        #expect(targets.flattened.path == Self.dir + testCase.flattened)
        #expect(targets.project?.path == testCase.project.map { Self.dir + $0 })
    }

    @Test("Saving twice plans the same files, so nothing piles up")
    func idempotent() {
        let first = EditorSaveTargets.plan(
            document: URL(fileURLWithPath: Self.dir + "X.png"),
            keepOriginal: true,
            writesProject: true,
            fileExists: { _ in false }
        )
        let second = EditorSaveTargets.plan(
            document: first.document,
            keepOriginal: true,
            writesProject: true,
            fileExists: { $0 == first.flattened }
        )
        #expect(first == second)
    }

    @Test("Save As to an image keeps writing that image")
    func chosen() throws {
        let url = URL(fileURLWithPath: Self.dir + "Bar.jpg")
        let targets = try #require(EditorSaveTargets.chosen(url, writesProject: true))
        #expect(targets.flattened == url)
        #expect(targets.project?.lastPathComponent == "Bar.kadr")
        #expect(targets.document.lastPathComponent == "Bar.kadr")
        #expect(EditorSaveTargets.chosen(url, writesProject: false)?.document == url)
        #expect(EditorSaveTargets.chosen(URL(fileURLWithPath: "/a/B.kadr"), writesProject: true) == nil)
    }
}
