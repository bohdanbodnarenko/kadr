import Testing
@testable import HistoryKit

@Suite("HistoryKit module")
struct HistoryKitModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(HistoryKitModule.identifier == "HistoryKit")
        #expect(HistoryKitModule.layer == 2)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in HistoryKitModule.dependencies {
            #expect(dependency.layer < HistoryKitModule.layer, "\(dependency.name) is not below HistoryKit")
            #expect(dependency.name != HistoryKitModule.identifier)
        }
    }
}
