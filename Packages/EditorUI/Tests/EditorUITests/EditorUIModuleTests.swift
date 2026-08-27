import Testing
@testable import EditorUI

@Suite("EditorUI module")
struct EditorUIModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(EditorUIModule.identifier == "EditorUI")
        #expect(EditorUIModule.layer == 3)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in EditorUIModule.dependencies {
            #expect(dependency.layer < EditorUIModule.layer, "\(dependency.name) is not below EditorUI")
            #expect(dependency.name != EditorUIModule.identifier)
        }
    }
}
