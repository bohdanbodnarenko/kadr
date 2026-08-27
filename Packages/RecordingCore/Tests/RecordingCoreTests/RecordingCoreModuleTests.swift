import Testing
@testable import RecordingCore

@Suite("RecordingCore module")
struct RecordingCoreModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(RecordingCoreModule.identifier == "RecordingCore")
        #expect(RecordingCoreModule.layer == 2)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in RecordingCoreModule.dependencies {
            #expect(dependency.layer < RecordingCoreModule.layer, "\(dependency.name) is not below RecordingCore")
            #expect(dependency.name != RecordingCoreModule.identifier)
        }
    }
}
