import Testing
@testable import SelectionUI

@Suite("SelectionUI module")
struct SelectionUIModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(SelectionUIModule.identifier == "SelectionUI")
        #expect(SelectionUIModule.layer == 2)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in SelectionUIModule.dependencies {
            #expect(dependency.layer < SelectionUIModule.layer, "\(dependency.name) is not below SelectionUI")
            #expect(dependency.name != SelectionUIModule.identifier)
        }
    }
}
