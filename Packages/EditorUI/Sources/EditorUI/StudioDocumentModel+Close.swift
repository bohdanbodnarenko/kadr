import Foundation
import StudioSession

@MainActor
public extension StudioDocumentModel {
    /// Records that the window closed on purpose (docs/09 U3.1).
    ///
    /// The draft says "somebody was in the middle of this" and the commit says "somebody
    /// stopped on purpose", and the difference between them is the entire definition of a
    /// session a crash interrupted. Without this every session anyone ever opened would
    /// look unfinished forever, and a recovery prompt that is always showing is one nobody
    /// reads.
    ///
    /// The draft stays. It is what reopening reads first, and after a clean close the two
    /// agree — so keeping it costs nothing and losing it would throw away the position the
    /// user left off at.
    ///
    /// Also where the studio lets go of what it started: the transcript check stops reading
    /// the footage, and the filmstrip forgets this recording's decoders and tiles.
    func commitOnClose() {
        transcriptLoadTask?.cancel()
        transcriptLoadTask = nil
        flushDraft()
        do {
            try document.commit(edit)
            // Only once the edit is on disk: until then undo can still reach a replaced
            // or removed import, and after it nothing can.
            session.purgeUnusedImports(keeping: edit)
        } catch {
            logger.error("Could not commit the studio edit: \(error.localizedDescription, privacy: .public)")
        }
        purgeStagedRenders()
        let path = session.screenURL.path
        Task.detached(priority: .utility) {
            await StudioThumbnailStore.shared.purge(path: path)
        }
    }
}
