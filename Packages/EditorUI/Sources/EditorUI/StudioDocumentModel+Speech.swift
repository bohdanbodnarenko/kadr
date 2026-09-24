import Foundation
import os
import Shared
import StudioRender
import StudioSession

/// Transcribing a recording and cutting the filler words out of it (docs/09 U3.6, docs/13).
@MainActor
public extension StudioDocumentModel {
    // MARK: - Speech

    /// Loads the persisted transcript once it has been checked against the footage.
    ///
    /// Started by `init` and awaited by nobody on the way in: validating a transcript means
    /// proving the footage is the one it was made from, and on a miss that is a SHA-256 of
    /// the whole movie. That runs detached at utility priority, stops reading when the studio
    /// closes, and is skipped outright when the fingerprint beside the transcript says the
    /// file has not changed (`SessionDocument.audioContentHash()`).
    ///
    /// A transcript produced by Tidy Speech while this was running wins: it is newer by
    /// construction, and overwriting it with the stored one would undo what the user just
    /// asked for.
    func loadTranscript() async {
        let document = document
        let check = Task.detached(priority: .utility) { () -> Transcript? in
            let signposter = KadrLog.signposter(.app)
            let state = signposter.beginInterval("studio.transcript.hash")
            defer { signposter.endInterval("studio.transcript.hash", state) }
            return try? document.transcriptMatchingFootage()
        }
        let loaded = await withTaskCancellationHandler {
            await check.value
        } onCancel: {
            check.cancel()
        }
        guard !Task.isCancelled, let loaded, transcript == nil else { return }
        transcript = loaded
        chapters = ChapterMarks.marks(from: loaded, duration: manifest.duration)
    }

    /// Waits for the transcript check `init` started. For tests, and for anything that
    /// needs the stored transcript before it acts.
    func transcriptLoaded() async {
        await transcriptLoadTask?.value
    }

    func refreshSpeechStatus() async {
        let locale = SpeechLanguage.currentIdentifier(speechLocaleIdentifier)
        do {
            let response = try await VisionClient().speechStatus(SpeechStatusRequest(localeIdentifier: locale))
            speechStatus = response.status
            supportedLocales = response.supportedLocales
            dictationSettingsNeeded = response.dictationSettingsNeeded
            let resolved = SpeechLanguage.resolved(speechLocaleIdentifier, supported: response.supportedLocales)
            if !response.supportedLocales.isEmpty {
                speechLocaleIdentifier = resolved
            }
        } catch {
            speechStatus = .notApplicable
        }
    }

    func warmUpSpeech() {
        let locale = SpeechLanguage.currentIdentifier(speechLocaleIdentifier)
        Task { @MainActor [weak self] in
            try? await VisionClient().warmUpSpeech(SpeechStatusRequest(localeIdentifier: locale))
            await self?.refreshSpeechStatus()
        }
    }

    func installSpeechModel() {
        guard installTask == nil else { return }
        installProgress = 0
        let locale = SpeechLanguage.currentIdentifier(speechLocaleIdentifier)

        installTask = Task { @MainActor [self] in
            defer {
                installTask = nil
                installProgress = nil
            }
            do {
                let client = VisionClient()
                defer { client.disconnect() }
                _ = try await client.installSpeechModel(SpeechInstallRequest(localeIdentifier: locale)) { progress in
                    Task { @MainActor [weak self] in self?.installProgress = progress }
                }
                await refreshSpeechStatus()
                notice = "The language model is installed. Speech is ready to use."
            } catch is CancellationError {
                // Silent: the user cancelled it, so they already know.
            } catch VisionServiceError.insufficientDiskSpace {
                failure = .speechModelStorageFull()
            } catch {
                failure = .speechModelDownloadFailed(error.localizedDescription)
            }
        }
    }

    /// Cancelling the task is what stops the download: the client sends the cancel on
    /// the install's own connection and drops it, which the helper treats as a cancel
    /// too (docs/17 T-STU-5). A fresh `VisionClient` here reached nothing.
    func cancelSpeechModelInstall() {
        installTask?.cancel()
        installTask = nil
        installProgress = nil
    }

    /// Transcribes the recording and proposes cuts. Does not apply them (docs/13 T0.4).
    func tidySpeech() async {
        guard !isTranscribing else { return }
        guard await transcriber.requestAuthorization() else {
            failure = .speechPermissionNeeded()
            return
        }

        isTranscribing = true
        transcriptionProgress = 0
        let task = Task { await runTidy() }
        transcribeTask = task
        await task.value
        transcribeTask = nil
        isTranscribing = false
        transcriptionProgress = nil
    }

    /// Cancels through the transcription's own task, and so its own connection
    /// (docs/17 T-STU-5).
    func cancelTidySpeech() {
        transcribeTask?.cancel()
    }

    private func runTidy() async {
        do {
            try Task.checkCancellation()
            let options = TranscriptionOptions(
                localeIdentifier: SpeechLanguage.currentIdentifier(speechLocaleIdentifier),
                tracks: .all
            )
            let produced = try await transcriber.transcribe(
                audioAt: session.screenURL,
                options: options
            ) { [weak self] fraction in
                Task { @MainActor in self?.transcriptionProgress = fraction }
            }
            try Task.checkCancellation()
            adopt(produced)
        } catch is CancellationError {
            logger.info("Transcription cancelled")
        } catch TranscriptionError.unavailableOnDevice {
            await refreshSpeechStatus()
            if dictationSettingsNeeded {
                failure = .transcriptionFailed(
                    "On-device dictation is not enabled for this language. Turn it on in "
                        + "System Settings ▸ Keyboard ▸ Dictation, then try again."
                )
            } else {
                failure = .transcriptionFailed(
                    "There is no speech model on this Mac for your language yet."
                )
            }
        } catch TranscriptionError.noAudioTrack {
            failure = .transcriptionFailed("This recording has no sound in it.")
        } catch TranscriptionError.notAuthorized {
            failure = .speechPermissionNeeded()
        } catch {
            failure = .transcriptionFailed(error.localizedDescription)
        }
    }

    private func adopt(_ produced: Transcript) {
        if produced.timingsLookCollapsed(relativeTo: manifest.duration) {
            failure = .transcriptionFailed(
                "The transcript had no usable timings, so nothing was cut. "
                    + "This can happen when dictation is not enabled on this Mac."
            )
            return
        }
        guard produced.spanLooksPlausible(relativeTo: manifest.duration) else {
            failure = .transcriptionFailed(
                "The transcript did not match the length of this recording, so nothing was cut."
            )
            return
        }

        let processed = TranscriptPostProcessor().processed(produced)
        transcript = processed
        chapters = ChapterMarks.marks(from: processed, duration: manifest.duration)
        try? document.write(processed)

        let planner = tidyPlanner
        // Tidy only runs on an uncut recording, so the telemetry's time is the edit's.
        let cuts = planner.cuts(
            for: processed,
            duration: manifest.duration,
            protecting: TranscriptCutPlanner.activityRanges(in: telemetry)
        )
        guard !cuts.isEmpty else {
            notice = tidyNothingFoundNotice
            pendingCuts = []
            selectedCutIDs = []
            requiresCutConfirmation = false
            return
        }

        pendingCuts = cuts
        selectedCutIDs = Set(cuts.map(\.id))
        requiresCutConfirmation = planner.exceedsRemovalCap(cuts, duration: edit.clips.editedDuration)
        notice = requiresCutConfirmation
            ? "This would remove more than 40% of the recording. Review the list and confirm before applying."
            : "Review the proposed cuts, then apply. Nothing has been changed yet."
    }

    /// Applies the selected cuts as clip boundaries.
    func applyPendingCuts(confirmingLargeRemoval: Bool = false) {
        let cuts = pendingCuts.filter { selectedCutIDs.contains($0.id) }
        guard !cuts.isEmpty else {
            notice = "No cuts were selected."
            return
        }
        let planner = TranscriptCutPlanner()
        if planner.exceedsRemovalCap(cuts, duration: edit.clips.editedDuration), !confirmingLargeRemoval {
            requiresCutConfirmation = true
            failure = StudioFailurePresentation(
                title: "Remove more than 40% of this recording?",
                message: "Confirm to apply the selected cuts anyway.",
                style: .sheet,
                primaryAction: .retry,
                secondaryAction: .dismiss
            )
            return
        }
        let timeline = planner.applying(cuts, to: edit.clips)
        guard !timeline.clips.isEmpty, timeline.editedDuration > 0 else {
            notice = "Tidying would leave nothing to play. The recording was left as it is."
            return
        }
        change { $0.clips = timeline }
        playhead = min(playhead, edit.duration)
        pendingCuts = []
        selectedCutIDs = []
        requiresCutConfirmation = false
        notice = "Removed \(cuts.count) \(cuts.count == 1 ? "passage" : "passages")."
    }

    func discardPendingCuts() {
        pendingCuts = []
        selectedCutIDs = []
        requiresCutConfirmation = false
    }

    /// The planner for what the user chose to tidy (docs/17 T-STU-6).
    internal var tidyPlanner: TranscriptCutPlanner {
        TranscriptCutPlanner(removesFillers: tidyRemovesFillers, removesSilences: tidyShortensPauses)
    }

    private var tidyNothingFoundNotice: String {
        switch (tidyRemovesFillers, tidyShortensPauses) {
        case (true, false): "There were no filler words to remove."
        case (false, true): "There were no long pauses to shorten."
        default: "There were no filler words or long pauses to tidy."
        }
    }

    func toggleCut(_ id: UUID) {
        if selectedCutIDs.contains(id) {
            selectedCutIDs.remove(id)
        } else {
            selectedCutIDs.insert(id)
        }
        let planner = TranscriptCutPlanner()
        let selected = pendingCuts.filter { selectedCutIDs.contains($0.id) }
        requiresCutConfirmation = planner.exceedsRemovalCap(selected, duration: edit.clips.editedDuration)
    }

    func seekToCut(_ cut: ProposedCut) {
        playhead = edit.clips.editedTime(forSource: cut.start) ?? 0
    }

    func seekToWord(_ word: TranscriptWord) {
        playhead = edit.clips.editedTime(forSource: word.start) ?? playhead
    }

    func cutSentence(containing word: TranscriptWord) {
        cutWords(sentence(containing: word))
    }

    /// Cuts the selected words' footage out of the video (docs/03 §1.9).
    func cutWords(_ words: [TranscriptWord]) {
        guard let first = words.first, let last = words.last else { return }
        cutSourceRange(from: first.start, to: last.end)
    }

    func cutSourceRange(from start: TimeInterval, to end: TimeInterval) {
        change { edit in
            edit.clips = edit.clips.removingSourceRange(from: start, to: end)
        }
        playhead = edit.clips.editedTime(forSource: end) ?? min(playhead, edit.clips.editedDuration)
    }

    /// Whether this word's footage still survives in the edit.
    func transcriptWordSurvives(_ word: TranscriptWord) -> Bool {
        edit.clips.containsSourceTime((word.start + word.end) / 2)
    }

    func isFillerWord(_ word: TranscriptWord) -> Bool {
        TranscriptCutPlanner.fillerWords.contains(word.normalized)
    }

    /// The word being said at the playhead, if the transcript covers that moment.
    func activeTranscriptWord(in words: [TranscriptWord]) -> TranscriptWord? {
        Self.activeWord(in: words, atEdited: playhead, clips: edit.clips)
    }

    /// The word being said at an edited-time instant.
    ///
    /// Static and explicit about its inputs so the transcript's playhead leaf can call it
    /// without reading the model — which would subscribe it to every edit.
    nonisolated static func activeWord(
        in words: [TranscriptWord],
        atEdited time: TimeInterval,
        clips: ClipTimeline
    ) -> TranscriptWord? {
        let source = clips.sourceTime(forEdited: time) ?? time
        return words.first { source >= $0.start && source < $0.end }
            ?? words.last { $0.start <= source }
    }

    var visibleTranscriptWords: [TranscriptWord] {
        Self.visibleWords(in: transcript, query: transcriptQuery)
    }

    nonisolated static func visibleWords(in transcript: Transcript?, query: String) -> [TranscriptWord] {
        guard let transcript else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return transcript.words }
        return transcript.words.filter { $0.text.lowercased().contains(query) }
    }

    func sentence(containing word: TranscriptWord) -> [TranscriptWord] {
        guard let transcript else { return [word] }
        guard let index = transcript.words.firstIndex(of: word) else { return [word] }
        var start = index
        while start > 0 {
            let previous = transcript.words[start - 1]
            if let last = previous.text.last, ".!?。！？".contains(last) {
                break
            }
            if word.start - previous.end > 1.1 {
                break
            }
            start -= 1
        }
        var end = index
        while end < transcript.words.count - 1 {
            let current = transcript.words[end]
            if let last = current.text.last, ".!?。！？".contains(last) {
                break
            }
            let next = transcript.words[end + 1]
            if next.start - current.end > 1.1 {
                break
            }
            end += 1
        }
        return Array(transcript.words[start ... end])
    }
}
