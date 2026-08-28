import AnnotationModel
import Foundation

/// Background removal, from the editor's side (docs/03 §3 P3, docs/06 M23).
public extension EditorDocumentModel {
    var hasSubjectLift: Bool {
        document.subjectLift != nil
    }

    var subjectLiftBackground: SubjectLiftBackground {
        document.subjectLift?.background ?? .transparent
    }

    func startSubjectLift() {
        isLiftingSubject = true
        subjectLiftError = nil
    }

    /// Applies a mask the helper produced. One undo step.
    func applySubjectLift(maskPNG: Data) {
        isLiftingSubject = false
        subjectLiftError = nil
        document.setSubjectLift(SubjectLiftSpec(
            maskPNG: maskPNG,
            background: subjectLiftBackground
        ))
    }

    func failSubjectLift(_ message: String) {
        isLiftingSubject = false
        subjectLiftError = message
    }

    func removeSubjectLift() {
        isLiftingSubject = false
        subjectLiftError = nil
        document.setSubjectLift(nil)
    }

    /// Swaps what fills the space the background used to occupy, keeping the mask.
    ///
    /// Keeping the mask matters: re-running the segmentation to change a colour would
    /// wake the helper, reload the model, and give the same answer.
    func setSubjectLiftBackground(_ background: SubjectLiftBackground) {
        guard var spec = document.subjectLift, spec.background != background else { return }
        spec.background = background
        document.setSubjectLift(spec)
    }
}
