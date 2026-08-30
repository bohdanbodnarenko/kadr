import Testing
@testable import EditorUI

@Suite("EditorUI module")
struct EditorUIModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(EditorUIModule.identifier == "EditorUI")
        #expect(EditorUIModule.layer == 3)
    }

    @Test("The toolbar groups still cover every tool")
    func toolbarGroupsCoverEveryTool() {
        let grouped: Set<EditorTool> = [
            .select,
            .arrow, .shape, .line, .freehand, .highlighter, .text,
            .redaction, .counter, .crop, .measure
        ]
        #expect(grouped == Set(EditorTool.allCases))
    }
}
