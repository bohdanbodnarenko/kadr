import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dragging the flattened image out of the editor (docs/18 ED-3).
@MainActor
public extension EditorDocumentModel {
    /// A provider that renders the image as it looks now, annotations and redactions
    /// burned in, only when the receiver asks for the file. Nil when the host has not said
    /// how to render.
    func flattenedImageItemProvider() -> NSItemProvider? {
        guard let render = flattenedFileRenderer else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = flattenedDragName
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                do {
                    try await completion(render(), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}
