import Foundation
import StudioRender
import StudioSession
import Testing
@testable import EditorUI

/// What the studio does about speech, and — more importantly — what it does without it
/// (docs/09 U3.6).
///
/// Its own suite because the property under test is a negative one: that the language
/// model is optional, that nothing waits for it, and that a machine which is offline or
/// has no model behaves exactly as it would if the installer had never been written. That
/// claim is easy to break by accident and invisible when it breaks, so it is asserted
/// rather than assumed.
@MainActor
@Suite("Studio speech")
struct StudioSpeechTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-speech-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(
        in folder: URL,
        duration: TimeInterval = 10,
        telemetry: InputTelemetry = InputTelemetry(),
        transcriber: (any Transcribing)? = nil
    ) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)

        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            scale: 2,
            frameRate: 60,
            duration: duration,
            hasBakedCursor: true,
            hasCamera: false
        ))
        return try #require(StudioDocumentModel(session: session, transcriber: transcriber))
    }

    /// The guarantee the whole arrangement rests on: the studio opens, and everything in it
    /// works, without ever having consulted the speech catalogue. A model checked at launch
    /// would be a network-adjacent call on every recording somebody opens, including the
    /// ones they never intend to transcribe.
    @Test("Opening a session asks nothing about speech models")
    func speechIsNotConsultedOnOpen() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(studio.speechStatus == nil, "the speech catalogue was consulted before anybody asked")
        #expect(studio.installProgress == nil)
        #expect(!studio.isTranscribing)
    }

    /// Editing must never depend on a model, a download or a network. This walks the whole
    /// editing surface with the catalogue untouched and asserts it all still works.
    @Test("Every edit works without a speech model")
    func editingIsIndependentOfSpeech() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.playhead = 4
        studio.splitAtPlayhead()
        studio.addZoom()
        studio.setSpeedAtPlayhead(2)
        studio.change { $0.reframe.aspect = .nineSixteen }
        studio.undo()
        studio.redo()

        #expect(studio.edit.clips.clips.count == 2)
        #expect(studio.edit.zooms.count == 1)
        #expect(studio.failure == nil)
        #expect(studio.speechStatus == nil, "an edit reached for the speech catalogue")
    }

    /// Cancelling has to be immediate and total, because a download nobody can stop is a
    /// download that owns the machine.
    @Test("Cancelling a download clears its state at once")
    func cancelClearsInstallState() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.installSpeechModel()
        studio.cancelSpeechModelInstall()
        #expect(studio.installProgress == nil)
    }

    /// Asking twice must not start two of them: two downloads of one model is twice the
    /// bytes and a progress bar that jumps backwards.
    @Test("Starting a download twice does not start two")
    func installIsNotReentrant() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.installSpeechModel()
        let first = studio.installProgress
        studio.installSpeechModel()
        #expect(studio.installProgress == first)
        studio.cancelSpeechModelInstall()
    }

    // MARK: - Clean closes

    /// The distinction crash recovery rests on: a draft says somebody was in the middle of
    /// this, a commit says they stopped on purpose. Without the commit every session anyone
    /// ever opened would look interrupted forever.
    @Test("A freshly edited session looks unfinished until it is closed")
    func editingLeavesASessionUnfinished() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.session.needsRecovery, "an untouched session is not a rescue")

        studio.change { $0.showsClicks = false }
        #expect(studio.session.needsRecovery, "an edit in progress should read as interrupted")

        studio.commitOnClose()
        #expect(!studio.session.needsRecovery, "a session closed on purpose is not a rescue")
    }

    /// Reopening has to land where the user left off, so the draft outlives the commit
    /// rather than being cleared by it.
    @Test("Committing on close keeps the draft")
    func commitKeepsTheDraft() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.camera.sizeFraction = 0.4 }
        studio.commitOnClose()

        let reopened = try #require(StudioDocumentModel(session: studio.session))
        #expect(reopened.edit.camera.sizeFraction == 0.4)
    }

    @Test("Exporting also settles the session")
    func exportCommits() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.showsKeystrokes = false }
        studio.commitOnClose()
        #expect(!studio.session.needsRecovery)
    }

    // MARK: - Time bases

    /// `TranscriptCutPlanner.applying` rebuilds a timeline from scratch at natural speed,
    /// so it can only be used on an untouched one. Applied over an existing edit it
    /// silently threw away every cut and speed change the user had already made — record
    /// sixty seconds, set 2×, press Tidy speech, and the speed was gone and the tail was
    /// deleted (docs/10 R0.2).
    @Test("Tidying refuses an edit it would otherwise silently discard")
    func tidyingRefusesAnEditedTimeline() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.setSpeedAtPlayhead(2)
        let before = studio.edit.clips
        #expect(before.isEdited(ofRecordingLasting: 10), "the fixture did not actually change the timeline")

        studio.refuseTidyIfEditedForTesting()
        #expect(studio.edit.clips == before, "the user's speed change was discarded")
        #expect(studio.failure != nil, "the refusal said nothing")
    }

    @Test("An untouched timeline is not refused")
    func untouchedTimelineIsAllowed() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.edit.clips.isEdited(ofRecordingLasting: 10))
        studio.refuseTidyIfEditedForTesting()
        #expect(studio.failure == nil)
    }

    /// Cues are stored in source time (docs/16 STU-A3), so a cut of the first ten seconds
    /// keeps a cluster at 25 s of footage on 25 s of source, not 15 s of edit.
    @Test("Smart zooms stay on the source frame after a cut")
    func smartZoomsUseSourceTime() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        var telemetry = InputTelemetry()
        telemetry.clicks = (0 ..< 6).map {
            ClickEvent(time: 25 + Double($0) * 0.2, position: CGPoint(x: 500, y: 500))
        }
        let studio = try model(in: folder, duration: 30, telemetry: telemetry)

        studio.change { $0.clips = ClipTimeline(clips: [Clip(sourceStart: 10, sourceDuration: 20)]) }
        studio.planSmartZooms()

        let cue = try #require(studio.edit.zooms.first)
        #expect(abs(cue.start - 25) < 2, "the cue landed at \(cue.start)s rather than about 25s of source")
    }

    // MARK: - tidySpeech (docs/13 T0.2)

    @Test("A fixture transcript produces a review list and does not apply cuts")
    func tidySpeechProducesReviewList() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = StubTranscriber(transcript: Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.4),
            TranscriptWord(text: "um", start: 0.5, end: 0.8),
            TranscriptWord(text: "world", start: 0.9, end: 1.4)
        ]))
        let studio = try model(in: folder, duration: 2, transcriber: stub)
        let before = studio.edit.clips
        await studio.tidySpeech()
        #expect(stub.calls == 1)
        #expect(!studio.pendingCuts.isEmpty, "the review list was empty")
        #expect(studio.pendingCuts.contains { $0.reason == .fillerWord })
        #expect(studio.edit.clips == before, "cuts were applied without a review")
        #expect(studio.transcript != nil)
    }

    /// docs/18 STU-4: captions without Find Cuts.
    @Test("Transcribe makes a transcript and proposes no cuts")
    func transcribeOnlyProposesNothing() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = StubTranscriber(transcript: Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.4),
            TranscriptWord(text: "um", start: 0.5, end: 0.8),
            TranscriptWord(text: "world", start: 0.9, end: 1.4)
        ]))
        let studio = try model(in: folder, duration: 2, transcriber: stub)
        let before = studio.edit.clips
        await studio.transcribeOnly()
        #expect(stub.calls == 1)
        #expect(studio.transcript != nil)
        #expect(studio.pendingCuts.isEmpty)
        #expect(studio.edit.clips == before)
    }

    /// docs/17 T-STU-6, through the model: the telemetry it loaded from disk protects the
    /// silent demonstration, and switching pauses off leaves only the fillers.
    @Test("Tidy leaves silent on-screen work alone and honours its toggles")
    func tidyProtectsDemonstrations() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let words = Transcript(words: [
            TranscriptWord(text: "um", start: 0, end: 0.3),
            TranscriptWord(text: "Watch", start: 0.4, end: 1),
            TranscriptWord(text: "this", start: 8, end: 9)
        ])
        let telemetry = InputTelemetry(clicks: (2 ... 7).map { ClickEvent(time: Double($0), position: .zero) })
        let studio = try model(
            in: folder,
            duration: 9,
            telemetry: telemetry,
            transcriber: StubTranscriber(transcript: words)
        )

        await studio.tidySpeech()
        #expect(studio.pendingCuts.allSatisfy { $0.reason == .fillerWord || $0.end <= 1.7 || $0.start >= 7.3 })

        studio.discardPendingCuts()
        studio.tidyShortensPauses = false
        await studio.tidySpeech()
        #expect(!studio.pendingCuts.isEmpty)
        #expect(studio.pendingCuts.allSatisfy { $0.reason == .fillerWord })
    }

    @Test("Zero timestamps refuse rather than collapse the timeline (T-C3)")
    func tidySpeechRefusesCollapsedTimestamps() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = StubTranscriber(transcript: Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.1),
            TranscriptWord(text: "world", start: 0.1, end: 0.2)
        ]))
        let studio = try model(in: folder, duration: 600, transcriber: stub)
        let before = studio.edit.clips
        await studio.tidySpeech()
        #expect(studio.edit.clips == before)
        #expect(studio.pendingCuts.isEmpty)
        #expect(studio.failure != nil)
    }

    @Test("Narration then silence asks for confirmation instead of deleting 94% (T-C2)")
    func tidySpeechCapsDestructiveEdits() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = StubTranscriber(transcript: Transcript(words: [
            TranscriptWord(text: "Done", start: 0, end: 40)
        ]))
        let studio = try model(in: folder, duration: 600, transcriber: stub)
        let before = studio.edit.clips
        await studio.tidySpeech()
        #expect(studio.edit.clips == before, "the tail was cut without a review")
        #expect(studio.requiresCutConfirmation)
        #expect(!studio.pendingCuts.isEmpty)

        studio.applyPendingCuts(confirmingLargeRemoval: false)
        #expect(studio.edit.clips == before, "applying without confirmation still cut")

        studio.applyPendingCuts(confirmingLargeRemoval: true)
        #expect(studio.edit.clips != before)
        #expect(studio.edit.duration < 600)
    }

    @Test("Tidy Speech transcribes an already-trimmed timeline")
    func tidySpeechTranscribesAnEditedTimeline() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = StubTranscriber(transcript: Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 1),
            TranscriptWord(text: "um", start: 1.2, end: 1.5),
            TranscriptWord(text: "there", start: 1.7, end: 2.2)
        ]))
        let studio = try model(in: folder, transcriber: stub)
        studio.playhead = 2
        studio.trimStartToPlayhead()
        await studio.tidySpeech()
        #expect(stub.calls == 1, "transcription should still run after a trim")
        #expect(studio.failure == nil)
        #expect(!studio.pendingCuts.isEmpty)
    }

    /// The transcript is validated after the window opens, not before (docs/11 S2): the
    /// check hashes the whole recording, which used to block the main thread for seconds.
    @Test("A persisted transcript is reused on reopen")
    func transcriptPersists() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let transcript = try Transcript(
            words: [TranscriptWord(text: "Hello", start: 0, end: 1)],
            audioContentHash: AudioContentHash.hash(fileAt: studio.session.screenURL)
        )
        try studio.document.write(transcript)
        let reopened = try #require(StudioDocumentModel(session: studio.session, transcriber: StubTranscriber(
            transcript: Transcript()
        )))
        await reopened.transcriptLoaded()
        #expect(reopened.transcript?.words.first?.text == "Hello")
        #expect(reopened.document.audioHashCache() != nil, "the footage hash was not remembered")
    }

    @Test("A transcript of different footage is not loaded")
    func staleTranscriptIsDropped() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        try studio.document.write(Transcript(
            words: [TranscriptWord(text: "Hello", start: 0, end: 1)],
            audioContentHash: "not-this-footage"
        ))
        let reopened = try #require(StudioDocumentModel(session: studio.session))
        await reopened.transcriptLoaded()
        #expect(reopened.transcript == nil)
        #expect(reopened.chapters.isEmpty)
    }

    /// Closing mid-check must not leave a transcript appearing on a studio that is gone.
    @Test("Closing cancels the transcript check")
    func closingCancelsTheCheck() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        try studio.document.write(Transcript(words: [TranscriptWord(text: "Hello", start: 0, end: 1)]))
        let reopened = try #require(StudioDocumentModel(session: studio.session))
        reopened.commitOnClose()
        await reopened.transcriptLoaded()
        #expect(reopened.transcript == nil, "a cancelled check still delivered")
    }

    /// Tidy Speech finishing first wins: the stored transcript is older by construction.
    @Test("A fresh transcript is not replaced by the stored one")
    func freshTranscriptWins() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = StubTranscriber(transcript: Transcript(words: [
            TranscriptWord(text: "Fresh", start: 0, end: 0.4),
            TranscriptWord(text: "words", start: 0.5, end: 1.9)
        ]))
        let studio = try model(in: folder, duration: 2, transcriber: stub)
        try studio.document.write(Transcript(words: [TranscriptWord(text: "Stale", start: 0, end: 1)]))
        let reopened = try #require(StudioDocumentModel(session: studio.session, transcriber: stub))
        await reopened.tidySpeech()
        await reopened.transcriptLoaded()
        #expect(reopened.transcript?.words.first?.text == "Fresh")
    }

    @Test("Cutting selected words removes that stretch of the recording")
    func cutWordsRemovesTheRange() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, duration: 10)
        try studio.document.write(Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 1),
            TranscriptWord(text: "um", start: 1.2, end: 1.5),
            TranscriptWord(text: "world", start: 1.6, end: 2.2)
        ]))
        let reopened = try #require(StudioDocumentModel(session: studio.session))
        await reopened.transcriptLoaded()

        let um = try #require(reopened.transcript?.words.first { $0.text == "um" })
        #expect(reopened.transcriptWordSurvives(um))
        #expect(reopened.isFillerWord(um))

        reopened.cutWords([um])
        #expect(!reopened.transcriptWordSurvives(um))
        #expect(abs(reopened.edit.clips.editedDuration - 9.7) < 0.05)
        #expect(reopened.edit.clips.editedTime(forSource: 1.3) == nil)
    }

    @Test("Cutting a sentence still removes the whole spoken stretch")
    func cutSentenceRemovesTheWordsAroundIt() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, duration: 10)
        try studio.document.write(Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.4),
            TranscriptWord(text: "there.", start: 0.5, end: 1.0),
            TranscriptWord(text: "Next", start: 2.2, end: 2.6)
        ]))
        let reopened = try #require(StudioDocumentModel(session: studio.session))
        await reopened.transcriptLoaded()
        let hello = try #require(reopened.transcript?.words.first)

        reopened.cutSentence(containing: hello)
        #expect(reopened.edit.clips.editedTime(forSource: 0.2) == nil)
        #expect(reopened.edit.clips.editedTime(forSource: 2.3) != nil)
    }
}

final class StubTranscriber: Transcribing, @unchecked Sendable {
    var transcript: Transcript
    var calls = 0

    init(transcript: Transcript) {
        self.transcript = transcript
    }

    func transcribe(
        audioAt url: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        calls += 1
        progress?(1)
        return transcript
    }
}
