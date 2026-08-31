import Foundation
import os
import Shared
import StudioRender
import StudioSession

/// Transcribing a recording and cutting the filler words out of it (docs/09 U3.6, docs/13).
@MainActor
public extension StudioDocumentModel {
    // MARK: - Speech

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
                failure = "There is not enough free space on this Mac to download the language model."
            } catch {
                failure = "The language model could not be downloaded: \(error.localizedDescription)"
            }
        }
    }

    func cancelSpeechModelInstall() {
        installTask?.cancel()
        Task { @MainActor in
            VisionClient().cancelSpeech()
        }
        installTask = nil
        installProgress = nil
    }

    /// Transcribes the recording and proposes cuts. Does not apply them (docs/13 T0.4).
    func tidySpeech() async {
        guard !isTranscribing else { return }
        // Guard first, before minutes of transcription (docs/13 T-M1).
        guard !edit.clips.isEdited(ofRecordingLasting: manifest.duration) else {
            failure = Self.tidyRefusal
            return
        }
        guard await transcriber.requestAuthorization() else {
            failure = "Kadr needs permission to use speech recognition. Grant it in System Settings ▸ "
                + "Privacy & Security ▸ Speech Recognition."
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

    func cancelTidySpeech() {
        transcribeTask?.cancel()
        Task { @MainActor in
            VisionClient().cancelSpeech()
        }
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

            if produced.timingsLookCollapsed(relativeTo: manifest.duration) {
                failure = "The transcript had no usable timings, so nothing was cut. "
                    + "This can happen when dictation is not enabled on this Mac."
                return
            }
            guard produced.spanLooksPlausible(relativeTo: manifest.duration) else {
                failure = "The transcript did not match the length of this recording, so nothing was cut."
                return
            }

            let processed = TranscriptPostProcessor().processed(produced)
            transcript = processed
            chapters = ChapterMarks.marks(from: processed, duration: manifest.duration)
            try? document.write(processed)

            let planner = TranscriptCutPlanner()
            let cuts = planner.cuts(for: processed, duration: manifest.duration)
            guard !cuts.isEmpty else {
                notice = "There were no filler words or long pauses to remove."
                pendingCuts = []
                selectedCutIDs = []
                requiresCutConfirmation = false
                return
            }

            pendingCuts = cuts
            selectedCutIDs = Set(cuts.map(\.id))
            requiresCutConfirmation = planner.exceedsRemovalCap(cuts, duration: manifest.duration)
            notice = requiresCutConfirmation
                ? "This would remove more than 40% of the recording. Review the list and confirm before applying."
                : "Review the proposed cuts, then apply. Nothing has been changed yet."
        } catch is CancellationError {
            logger.info("Transcription cancelled")
        } catch TranscriptionError.unavailableOnDevice {
            await refreshSpeechStatus()
            if dictationSettingsNeeded {
                failure = "On-device dictation is not enabled for this language. Turn it on in "
                    + "System Settings ▸ Keyboard ▸ Dictation, then try again."
            } else {
                failure = "There is no speech model on this Mac for your language yet."
            }
        } catch TranscriptionError.noAudioTrack {
            failure = "This recording has no sound in it."
        } catch TranscriptionError.notAuthorized {
            failure = "Kadr needs permission to use speech recognition. Grant it in System Settings ▸ "
                + "Privacy & Security ▸ Speech Recognition."
        } catch {
            failure = "The recording could not be transcribed: \(error.localizedDescription)"
        }
    }

    /// Applies the selected cuts as clip boundaries.
    func applyPendingCuts(confirmingLargeRemoval: Bool = false) {
        let cuts = pendingCuts.filter { selectedCutIDs.contains($0.id) }
        guard !cuts.isEmpty else {
            notice = "No cuts were selected."
            return
        }
        guard !edit.clips.isEdited(ofRecordingLasting: manifest.duration) else {
            failure = Self.tidyRefusal
            return
        }
        let planner = TranscriptCutPlanner()
        if planner.exceedsRemovalCap(cuts, duration: manifest.duration), !confirmingLargeRemoval {
            requiresCutConfirmation = true
            failure = "This would remove more than 40% of the recording. Confirm to apply it anyway."
            return
        }
        let timeline = planner.applying(cuts, to: manifest.duration)
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

    func toggleCut(_ id: UUID) {
        if selectedCutIDs.contains(id) {
            selectedCutIDs.remove(id)
        } else {
            selectedCutIDs.insert(id)
        }
        let planner = TranscriptCutPlanner()
        let selected = pendingCuts.filter { selectedCutIDs.contains($0.id) }
        requiresCutConfirmation = planner.exceedsRemovalCap(selected, duration: manifest.duration)
    }

    func seekToCut(_ cut: ProposedCut) {
        playhead = edit.clips.editedTime(forSource: cut.start) ?? 0
    }

    func seekToWord(_ word: TranscriptWord) {
        playhead = edit.clips.editedTime(forSource: word.start) ?? playhead
    }

    func cutSentence(containing word: TranscriptWord) {
        let sentence = sentence(containing: word)
        guard let first = sentence.first, let last = sentence.last else { return }
        let start = first.start
        let end = last.end
        change { edit in
            var clips: [Clip] = []
            for clip in edit.clips.clips {
                let range = clip.sourceStart ..< (clip.sourceStart + clip.sourceDuration)
                if end <= range.lowerBound || start >= range.upperBound {
                    clips.append(clip)
                    continue
                }
                if start > range.lowerBound {
                    clips.append(Clip(
                        sourceStart: clip.sourceStart,
                        sourceDuration: start - clip.sourceStart,
                        speed: clip.speed
                    ))
                }
                if end < range.upperBound {
                    clips.append(Clip(
                        sourceStart: end,
                        sourceDuration: range.upperBound - end,
                        speed: clip.speed
                    ))
                }
            }
            edit.clips = ClipTimeline(clips: clips.filter { $0.sourceDuration > 0.02 })
        }
    }

    var visibleTranscriptWords: [TranscriptWord] {
        guard let transcript else { return [] }
        let query = transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
