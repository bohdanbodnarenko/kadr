import Foundation

@MainActor
public extension StudioDocumentModel {
    /// Runs a failed operation again, from its failure banner (docs/18 STU-2).
    func retry(_ operation: StudioFailurePresentation.Operation) async {
        switch operation {
        case let .export(destination):
            await export(to: destination)
        case .copyEdited:
            await copyEditedToClipboard()
        case .shareEdited:
            await shareEdited()
        case let .exportAudio(destination, format):
            await exportEditedAudio(to: destination, format: format)
        case .installSpeechModel:
            installSpeechModel()
        case .transcribe:
            await tidySpeech()
        }
    }
}
