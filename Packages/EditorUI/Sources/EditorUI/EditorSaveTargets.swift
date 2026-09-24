import AnnotationModel
import Foundation

/// Where ⌘S writes, worked out from the window's document and the agent's settings (T-ED-1).
///
/// The rest of Kadr pairs a flattened image with its project by stem: a card or History
/// row for `P.png` reopens `P.kadr` when one sits beside it (`CaptureProject.editorURL`).
/// So a save always writes one such pair, and the same pair on every later ⌘S, rather than
/// a new `… annotated 2.png` each time:
///
/// - **Keep original on:** the pair is `X annotated`, so the capture itself is never
///   touched. Saving a document that is already `… annotated` overwrites it in place.
/// - **Keep original off:** the pair is the document's own stem, so the flattened `X.png`
///   the card, clipboard and History use is rewritten along with `X.kadr`.
///
/// The project is written whenever the document *is* a project (it is the thing being
/// edited), and otherwise when the sidecar setting asks for one.
public struct EditorSaveTargets: Equatable, Sendable {
    /// The flattened image.
    public var flattened: URL
    /// The re-editable project beside it, when one is written.
    public var project: URL?

    public init(flattened: URL, project: URL?) {
        self.flattened = flattened
        self.project = project
    }

    static let annotatedSuffix = " annotated"
    public static let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"]

    /// The pair ⌘S writes for `document`.
    ///
    /// - Parameter fileExists: injected so the plan is a pure function of its inputs.
    public static func plan(
        document: URL,
        keepOriginal: Bool,
        writesProject: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> EditorSaveTargets {
        let isProject = document.pathExtension.lowercased() == KadrDocumentFile.fileExtension
        let directory = document.deletingLastPathComponent()
        let stem = document.deletingPathExtension().lastPathComponent
        let pairStem = keepOriginal && !stem.hasSuffix(annotatedSuffix) ? stem + annotatedSuffix : stem
        let base = directory.appendingPathComponent(pairStem)

        let flattened: URL = if !isProject, pairStem == stem {
            // Overwriting the document's own image keeps its format.
            document
        } else {
            imageExtensions
                .flatMap { [$0, $0.uppercased()] }
                .map { base.appendingPathExtension($0) }
                .first(where: fileExists)
                ?? base.appendingPathExtension("png")
        }
        let project = isProject || writesProject
            ? base.appendingPathExtension(KadrDocumentFile.fileExtension)
            : nil
        return EditorSaveTargets(flattened: flattened, project: project)
    }

    /// The pair for a destination the user picked in Save As: that file, and the project
    /// beside it when the setting asks for one. A picked `.kadr` is the project alone.
    public static func chosen(_ url: URL, writesProject: Bool) -> EditorSaveTargets? {
        guard url.pathExtension.lowercased() != KadrDocumentFile.fileExtension else { return nil }
        let project = writesProject
            ? url.deletingPathExtension().appendingPathExtension(KadrDocumentFile.fileExtension)
            : nil
        return EditorSaveTargets(flattened: url, project: project)
    }

    /// The file the window should represent after this pair is written: the project when
    /// there is one, since that is what reopens with the annotations still editable.
    public var document: URL {
        project ?? flattened
    }
}
