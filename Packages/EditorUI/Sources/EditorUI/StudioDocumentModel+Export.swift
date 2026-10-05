import AppKit
import Foundation
import MediaExport
import os
import Shared
import StudioRender
import StudioSession
import UserNotifications

/// Rendering the edit to a movie (docs/09 U3.3).
///
/// Its own file because an export is the one thing in the studio that takes minutes, cannot
/// be resumed, and writes somewhere the user chose — so it is the only operation here with a
/// lifecycle worth reading in one place: start it, watch it, stop it, and make sure that
/// whatever happens the destination is either the whole export or nothing at all.
@MainActor
public extension StudioDocumentModel {
    // MARK: - Exporting

    /// Puts the original recording on the clipboard as a file, the same way Quick Access
    /// Copy does. The edit is not in that file — Export is how the cuts and zooms leave.
    func copyOriginalToClipboard() {
        let url = session.screenURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    /// Renders the current edit, or reuses a stamped render, then copies it (docs/14 UX-31).
    ///
    /// Tracked as the export (docs/17 T-STU-4), so Cancel stops it, closing the window or
    /// quitting asks first, and a second ⌘C while it runs does not start another render.
    func copyEditedToClipboard() async {
        await runTrackedRender { model in
            do {
                let destination = try model.stagedRenderURL()
                try await model.writeEditedRecording(to: destination)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([destination as NSURL])
                model.notice = "Copied the edit to the clipboard."
            } catch where Self.isCancellation(error) {
                return
            } catch {
                model.failure = .copyEditedFailed(error.localizedDescription)
            }
        }
    }

    /// Renders the current edit for sharing (docs/14 UX-31), tracked like Copy.
    ///
    /// The picker hangs off the Share button when it is on screen, and off the studio
    /// window otherwise — never off whatever window happens to be key, which quietly
    /// dropped the result when the user had clicked elsewhere during the render.
    func shareEdited() async {
        await runTrackedRender { model in
            do {
                let destination = try model.stagedRenderURL()
                try await model.writeEditedRecording(to: destination)
                guard let view = model.shareAnchorView?.window != nil
                    ? model.shareAnchorView
                    : model.studioWindowContentView
                else { return }
                let picker = NSSharingServicePicker(items: [destination])
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } catch where Self.isCancellation(error) {
                return
            } catch {
                model.failure = .shareEditedFailed(error.localizedDescription)
            }
        }
    }

    /// The studio's own window, found through the share anchor or a window titled for
    /// this recording.
    private var studioWindowContentView: NSView? {
        if let window = shareAnchorView?.window {
            return window.contentView
        }
        return NSApp?.windows.first { $0.title == session.displayName && $0.isVisible }?.contentView
    }

    /// Runs `work` as the one render this window has, so everything that guards an export
    /// guards it too.
    private func runTrackedRender(_ work: @escaping @MainActor (StudioDocumentModel) async -> Void) async {
        guard exportTask == nil else { return }
        let task = Task { [self] in await work(self) }
        exportTask = task
        await task.value
        exportTask = nil
    }

    internal nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? StudioRenderer.RenderError, error == .cancelled {
            return true
        }
        return false
    }

    /// Where Copy and Share render to: `<project>.<ext>` in a folder of this session's own
    /// (docs/17 T-STU-4).
    ///
    /// It outlives the window: the clipboard holds only a file URL, so removing the file on
    /// close made a copy that died before it was pasted (docs/18 STU-1). Old folders are
    /// swept by age at the next editor launch instead.
    ///
    /// Named for the project because the recipient sees the name — `kadr-copy-<UUID>.mov`
    /// is what used to land in their Downloads — and kept in one folder so it can be
    /// cleaned up rather than accumulating a movie per ⌘C in the temporary directory.
    internal func stagedRenderURL() throws -> URL {
        let folder = stagingDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
            .appendingPathComponent(Self.safeFileName(session.displayName))
            .appendingPathExtension(StudioExportSettings.sharing.filenameExtension)
    }

    /// This session's staging folder for Copy and Share.
    internal var stagingDirectory: URL {
        Self.stagingRoot
            .appendingPathComponent(session.directory.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Every session's staging folder lives here.
    nonisolated static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr Studio Staging", isDirectory: true)
    }

    /// Deletes what Copy and Share left behind for this session.
    func purgeStagedRenders() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// A project name as a file name: no path separators, no colon (Finder's slash).
    internal nonisolated static func safeFileName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Recording" : String(cleaned.prefix(200))
    }

    /// Writes the current edit to `destination` with the sharing preset, reusing a stamped
    /// render when possible (docs/18 STU-6).
    private func writeEditedRecording(to destination: URL) async throws {
        let snapshot = exportSnapshot(settings: .sharing)
        if reuseRenderedFile(for: snapshot, at: destination) {
            return
        }
        exportProgress = 0
        flushDraft()
        try? document.commit(snapshot.edit)
        defer { exportProgress = nil }
        let output = try await exportMedia(snapshot, to: destination)
        recordStamp(output, for: snapshot, at: destination)
    }

    /// Renders the edit to `destination`.
    ///
    /// The edit is committed first, so a finished export is also the point the draft is
    /// measured against: reopening after exporting shows what was exported.
    func export(to destination: URL) async {
        await runTrackedRender { model in
            await model.performExport(to: destination)
        }
    }

    /// Whether a render is running.
    var isExporting: Bool {
        exportTask != nil
    }

    /// What this window is in the middle of that closing or quitting would end
    /// (docs/17 T-STU-9), in words for the alert. Empty when it is safe to go.
    ///
    /// One list, so the close and quit guards ask about everything at once. Asking about
    /// speech and then closing used to end a render running beside it without a word.
    var longOperations: [String] {
        var operations: [String] = []
        if isExporting {
            operations.append("an export")
        }
        if isTranscribing {
            operations.append("a transcription")
        }
        if installTask != nil {
            operations.append("a language model download")
        }
        if audioExportTask != nil {
            operations.append("an audio export")
        }
        return operations
    }

    /// Stops everything in `longOperations` and waits for the export and the audio export
    /// to delete their partial files.
    func cancelLongOperations() async {
        cancelTidySpeech()
        cancelSpeechModelInstall()
        audioExportTask?.cancel()
        await audioExportTask?.value
        await cancelExport()
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

    /// What an export renders, taken once when it starts (docs/17 T-STU-2).
    ///
    /// The inspector, the timeline and ⌘Z all stay live while a render runs. Reading
    /// `edit` again after the `await` stamped the render with whatever the user had
    /// changed in the meantime — so the next export of the *new* edit reused the old
    /// file — and timed the captions against clips the movie does not have.
    internal func exportSnapshot(settings: StudioExportSettings? = nil) -> StudioExportSnapshot {
        StudioExportSnapshot(
            edit: edit,
            transcript: transcript,
            settings: settings ?? exportSettings,
            inputsDigest: renderInputsDigest(edit: edit, transcript: transcript)
        )
    }

    /// Everything outside the edit that changes the pixels (docs/17 T-STU-1).
    internal func renderInputsDigest(edit: StudioEdit, transcript: Transcript?) -> String? {
        let info = Bundle.main.infoDictionary
        return RenderStamp.digest(of: StudioRenderInputs(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info?["CFBundleVersion"] as? String ?? "",
            rendererVersion: StudioRenderer.version,
            transcriptDigest: transcript.flatMap { RenderStamp.digest(of: $0) },
            wallpaper: session.wallpaperURL(for: edit).flatMap(RecordingSession.contentIdentity(of:)),
            soundtrack: session.soundtrackURL(for: edit).flatMap(RecordingSession.contentIdentity(of:))
        ))
    }

    /// Copies a previous render of this exact edit, if there is one and it is still there.
    private func reuseRenderedFile(for snapshot: StudioExportSnapshot, at destination: URL) -> Bool {
        guard let stamp = document.renderStamp(),
              let digest = RenderStamp.digest(of: snapshot.edit),
              let inputs = snapshot.inputsDigest,
              stamp.matches(
                  editDigest: digest,
                  pixelSize: StudioRenderPlan.outputSize(
                      edit: snapshot.edit,
                      sourceSize: manifest.pixelSize,
                      maxLongestEdge: snapshot.settings.maxLongestEdge
                  ),
                  settingsDigest: RenderStamp.digest(of: snapshot.settings),
                  inputsDigest: inputs
              )
        else {
            return false
        }
        let source = URL(fileURLWithPath: stamp.outputPath)
        guard source.pathExtension.lowercased() == destination.pathExtension.lowercased() else {
            return false
        }
        guard source.standardizedFileURL != destination.standardizedFileURL else { return true }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            // A copy that fails is not a reason to refuse the export — render it again.
            logger.error("Could not reuse a finished render: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func performExport(to destination: URL) async {
        // The stamp is finally read (docs/11 S2).
        //
        // `renderStamp()` and `matches(editDigest:pixelSize:)` were written, tested and had
        // zero production callers, so "do not re-render an unchanged edit" was a feature
        // that existed only in the type system. Pressing Export twice on a ten-minute
        // recording re-rendered the whole thing.
        //
        // Copying rather than handing over the old path: the user picked *this*
        // destination, and telling them the export succeeded while pointing at a file
        // somewhere else is not the same thing as exporting.
        let snapshot = exportSnapshot()
        if reuseRenderedFile(for: snapshot, at: destination) {
            notice = "That edit was already exported, so Kadr copied the finished file."
            writeCaptions(for: snapshot, beside: destination)
            return
        }

        // Said before minutes of rendering, not after them (docs/18 STU-5).
        if let estimate = estimatedExportBytes(for: snapshot),
           StudioRenderPartialFile.hasRoom(forEstimatedBytes: estimate, at: destination) == false {
            failure = .notEnoughSpaceToExport(
                ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .file),
                to: destination
            )
            return
        }

        exportProgress = 0
        // Any debounced draft write lands before the commit, so the two cannot disagree
        // about what was exported.
        flushDraft()
        try? document.commit(snapshot.edit)

        do {
            let output = try await exportMedia(snapshot, to: destination)
            recordStamp(output, for: snapshot, at: destination)
            writeCaptions(for: snapshot, beside: destination)
            exportProgress = nil
            notifyExportFinished(at: destination)
        } catch is CancellationError {
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch StudioRenderer.RenderError.cancelled {
            exportProgress = nil
            logger.info("Studio export cancelled")
        } catch {
            exportProgress = nil
            failure = .exportFailed(error.localizedDescription, to: destination)
            logger.error("Studio export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func exportMedia(
        _ snapshot: StudioExportSnapshot,
        to destination: URL
    ) async throws -> StudioRenderer.Output {
        if snapshot.settings.container == .gif {
            return try await exportGIF(snapshot, to: destination)
        }
        return try await renderMovie(snapshot, to: destination)
    }

    private func renderMovie(
        _ snapshot: StudioExportSnapshot,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StudioRenderer.Output {
        try await StudioRenderer().render(
            session: session,
            edit: snapshot.edit,
            to: destination,
            options: snapshot.settings.rendererOptions(manifestFrameRate: manifest.frameRate),
            transcript: snapshot.transcript,
            progress: progress ?? progressPublisher()
        )
    }

    /// A render progress callback that only reaches the main actor when the percent moves.
    ///
    /// The renderer reports once per frame — sixty times a second of footage — and each
    /// report used to spawn a MainActor task that wrote `exportProgress`, which re-rendered
    /// the export controls and repainted the Dock tile. A bar 120 points wide cannot show
    /// more than a hundred steps, so the rest were work for nothing. The filter runs on the
    /// renderer's side, under a lock, so the dropped reports never become tasks at all.
    private func progressPublisher() -> @Sendable (Double) -> Void {
        // `exportProgress` was just set to 0, which is what 0% looks like.
        publishedExportPercent = 0
        let lastPercent = OSAllocatedUnfairLock<Int?>(initialState: 0)
        return { [weak self] value in
            let percent = Self.exportPercent(value)
            let changed = lastPercent.withLock { last in
                guard last != percent else { return false }
                last = percent
                return true
            }
            guard changed else { return }
            Task { @MainActor [weak self] in
                self?.publishExportProgress(value)
            }
        }
    }

    /// Writes `exportProgress` only when its whole percent differs from the last one written.
    ///
    /// The second check, on the main actor, covers what the lock cannot: two reports that
    /// passed it in quick succession arriving in the other order.
    internal func publishExportProgress(_ value: Double) {
        guard exportProgress != nil else { return }
        let percent = Self.exportPercent(value)
        guard percent != publishedExportPercent else { return }
        publishedExportPercent = percent
        exportProgress = value
    }

    internal nonisolated static func exportPercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded(.down))
    }

    /// How much of a GIF export's progress bar the movie render takes; the encode has the
    /// rest.
    internal nonisolated static let gifRenderShare = 0.7

    /// A local notification when the studio window is not key (docs/16 STU-C6).
    ///
    /// Only the file name crosses into the task. The request is built after permission is
    /// granted, because `UNNotificationRequest` is not `Sendable` and capturing a finished
    /// one in the authorization callback handed a non-Sendable object across threads.
    private func notifyExportFinished(at destination: URL) {
        // No app (a test host) is not "in the background": there is nobody to notify.
        guard NSApp?.isActive == false else { return }
        // Notification Center throws for a process with no bundle, which is a test runner.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let fileName = destination.lastPathComponent
        Task {
            let center = UNUserNotificationCenter.current()
            guard await (try? center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Export finished"
            content.body = fileName
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: "studio.export.\(UUID().uuidString)",
                content: content,
                trigger: nil
            ))
        }
    }

    /// Movie first, then ImageIO (docs/03 §1.8). GIF is not a video container, so the
    /// renderer writes a throwaway MOV and the encoder samples it.
    private func exportGIF(
        _ snapshot: StudioExportSnapshot,
        to destination: URL
    ) async throws -> StudioRenderer.Output {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-gif-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        // One bar across both phases (docs/17 T-STU-7): it used to reach 100% at the end
        // of the movie and then sit there while the GIF was encoded.
        let publish = progressPublisher()
        let split = Self.gifRenderShare
        let movie = try await renderMovie(snapshot, to: temp) { publish($0 * split) }
        try Task.checkCancellation()
        _ = try await ImageIOGIFEncoder().encode(
            movieAt: temp,
            to: destination,
            options: snapshot.settings.gifOptions,
            progress: { publish(split + $0 * (1 - split)) }
        )
        return StudioRenderer.Output(
            fileURL: destination,
            pixelSize: movie.pixelSize,
            duration: movie.duration,
            frameCount: movie.frameCount
        )
    }

    private func recordStamp(
        _ output: StudioRenderer.Output,
        for snapshot: StudioExportSnapshot,
        at destination: URL
    ) {
        guard let digest = RenderStamp.digest(of: snapshot.edit) else { return }
        try? document.write(RenderStamp(
            editDigest: digest,
            outputPath: destination.path,
            pixelSize: output.pixelSize,
            settingsDigest: RenderStamp.digest(of: snapshot.settings),
            inputsDigest: snapshot.inputsDigest,
            outputIdentity: .of(path: destination.path)
        ))
    }

    /// SRT and VTT beside the movie (docs/13 T2.2). Tiny, and the reason the transcript
    /// was persisted. Timed against the snapshot's clips, which are the movie's.
    private func writeCaptions(for snapshot: StudioExportSnapshot, beside destination: URL) {
        guard let transcript = snapshot.transcript else { return }
        let base = destination.deletingPathExtension()
        let srt = CaptionExport.srt(from: transcript, timeline: snapshot.edit.clips)
        let vtt = CaptionExport.vtt(from: transcript, timeline: snapshot.edit.clips)
        try? srt.data(using: .utf8)?.write(to: base.appendingPathExtension("srt"), options: .atomic)
        try? vtt.data(using: .utf8)?.write(to: base.appendingPathExtension("vtt"), options: .atomic)
    }
}
