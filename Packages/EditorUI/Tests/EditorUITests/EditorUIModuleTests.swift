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
            .redaction, .spotlight, .counter, .sticker, .crop, .measure
        ]
        #expect(grouped == Set(EditorTool.allCases))
    }

    @Test("Save As is a distinct export from Save and Save Project")
    func saveAsIsItsOwnAction() {
        #expect(EditorRootView.ExportAction.save != .saveAs)
        #expect(EditorRootView.ExportAction.saveAs != .saveProject)
        #expect(EditorRootView.ExportAction.save != .saveProject)
    }
}
