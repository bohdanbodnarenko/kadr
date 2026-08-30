import Foundation
import os
import Shared
import StudioRender
import StudioSession

/// Rendering the edit to a movie (docs/09 U3.3).
///
/// Its own file because an export is the one thing in the studio that takes minutes, cannot
/// be resumed, and writes somewhere the user chose — so it is the only operation here with a
/// lifecycle worth reading in one place: start it, watch it, stop it, and make sure that
/// whatever happens the destination is either the whole export or nothing at all.
@MainActor
public extension StudioDocumentModel {
    // MARK: - Exporting

    /// Renders the edit to `destination`.
    ///
    /// The edit is committed first, so a finished export is also the point the draft is
    /// measured against: reopening after exporting shows what was exported.
    func export(to destination: URL) async {
        guard exportTask == nil else { return }
        let task = Task { await performExport(to: destination) }
        exportTask = task
        await task.value
        exportTask = nil
    }

    /// Whether a render is running.
    var isExporting: Bool {
        exportTask != nil
    }

    /// Stops an export and waits for it to finish tearing itself down (docs/11 S0.4).
    ///
    /// Waiting is the whole point. The renderer's `defer` is what deletes the half-written
    /// destination, and a `defer` only runs if something gives the Task a chance to unwind
    /// — so returning the instant `cancel()` is called would race the very cleanup this
    /// exists to guarantee, and leave behind exactly the truncated file it is meant to
    /// prevent.
    func cancelExport() async {
        guard let exportTask else { return }
        exportTask.cancel()
        await exportTask.value
    }

    private func performExport(to destination: URL) async {
        exportProgress = 0
        // Any debounced draft write lands before the commit, so the two cannot disagree
        // about what was exported.
        flushDraft()
        try? document.commit(edit)

        do {
            let output = try await StudioRenderer().render(
                session: session,
                edit: edit,
                to: destination,
                progress: { [weak self] value in
                    Task { @MainActor in self?.exportProgress = value }
                }
            )
            guard let digest = RenderStamp.digest(of: edit) else {
                exportProgress = nil
                return
            }
            try? document.write(RenderStamp(
                editDigest: digest,
                outputPath: output.fileURL.path,
                pixelSize: output.pixelSize
            ))
            exportProgress = nil
        } catch is CancellationError {
            // The user asked for this, so it is not a failure to report back to them. The
            // renderer's `defer` has already removed the partial file.
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch StudioRenderer.RenderError.cancelled {
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch {
            exportProgress = nil
            failure = "The export failed: \(error.localizedDescription)"
            logger.error("Studio export failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
