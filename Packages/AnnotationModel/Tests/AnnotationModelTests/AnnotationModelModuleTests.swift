import Testing
@testable import AnnotationModel

@Suite("AnnotationModel module")
struct AnnotationModelModuleTests {
    @Test("Module identity matches the package name")
    func moduleIdentity() {
        #expect(AnnotationModelModule.identifier == "AnnotationModel")
        #expect(AnnotationModelModule.layer == 1)
    }

    @Test("Every dependency sits in a strictly lower layer")
    func dependenciesAreLowerLayers() {
        for dependency in AnnotationModelModule.dependencies {
            #expect(dependency.layer < AnnotationModelModule.layer, "\(dependency.name) is not below AnnotationModel")
            #expect(dependency.name != AnnotationModelModule.identifier)
        }
    }
}
