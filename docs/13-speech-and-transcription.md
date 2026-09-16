# Speech & Transcription — Audit, VoiceInk Comparison, and the Plan

> Written 2026-08-31. Audits every speech surface in Kadr against **VoiceInk** (`Beingpax/VoiceInk`, a shipping, production-quality macOS voice-to-text app) and sets out the work to make Kadr's speech features fully local, genuinely useful, and better than the reference.
>
> **Verdict in one paragraph.** Kadr's *pure* speech code is good — `TranscriptCutPlanner`, `TranscriptAssembly`, `SpeechFollower` and `TeleprompterScript` are careful, well-tested, and show real judgment. Everything between those pure functions and a user is broken. The transcriber hands a **video container to an audio-only API**, so the best backend probably never runs at all; it reads the **wrong audio track** when the microphone is on; the cut planner will happily propose deleting **94% of a recording** and the UI applies it with no preview, no review list and no cap; nothing is cancellable, nothing reports progress, nothing is cached or persisted; and "Follow my voice" ships as a live toggle for a feature that was deleted — whose only observable effect is to grey out the pace slider. None of this has ever been caught because `tidySpeech` has **no test that calls it**.

## ⚠️ Licence: VoiceInk is GPL-3.0 — study only

VoiceInk is **GPL-3.0**. Kadr is MIT. **No VoiceInk code may be copied, adapted, or line-by-line ported into Kadr** — the same rule this project already applies to QuickRecorder (AGPL), Capso (BUSL) and Screendrop's tldraw-derived `Engine/` (docs/08 §1). What follows describes *designs, algorithms and parameter values* observed in a reference implementation; every one must be re-implemented from the description. Add a line to the PR template: *"contains no code derived from VoiceInk."*

Third-party components VoiceInk builds on that **are** MIT-compatible and could be adopted directly: **whisper.cpp** (MIT). Anything else (FluidAudio/Parakeet, transcribe.cpp, model weights) needs its licence verified before adoption — model weights carry their own terms independent of the runtime.

---

## 1. What Kadr has today

### 1.1 Inventory

| File | Purpose | Reachable? | Tested? |
|---|---|---|---|
| `StudioRender/Transcriber.swift` | `Transcribing` protocol; `AnalyzerTranscriber` (macOS 26 `SpeechAnalyzer`) + `LegacyTranscriber` (`SFSpeechRecognizer`, on-device only) | yes, one call site | **no behavioural tests** |
| `StudioRender/TranscriptAssembly.swift` | splits a timed run into words, apportioned by character count | macOS 26 only | yes, 11 tests, good |
| `StudioRender/TranscriptCutPlanner.swift` | filler/silence cut planning → `ClipTimeline` | indirectly | yes, 24 tests, best code here |
| `StudioRender/SpeechModelInstaller.swift` | `AssetInventory` install, 5-state status | yes (button) | contract only |
| `StudioSession/SpeechFollower.swift` | phrase matching: where in the script is the reader | **no — nothing feeds it** | yes, 16 tests |
| `Kadr/Recording/LiveSpeechFollower.swift` | *was* the `SFSpeechRecognizer` bridge | constructed; `start()` returns `false` always | no |
| `EditorUI/StudioDocumentModel+Speech.swift` | `tidySpeech`, install/cancel | yes | 10 tests, **none call `tidySpeech`** |
| `Kadr/Settings/TeleprompterSection.swift` | script, pace, size, mirror, **"Follow my voice"** | yes | no |

**Absent entirely:** audio extraction, transcript persistence or caching, captions/subtitles, SRT/VTT export, a transcript view, click-a-word-to-seek, a cut-review list, language selection, progress, cancellation, streaming.

### 1.2 Findings

**CRITICAL**

- **T-C1 · The macOS 26 path is handed a video file through an audio-only API.** `Transcriber.swift:114-119` opens `session.screenURL` with `AVAudioFile(forReading:)`. That file is written by `SegmentWriter` as `AVAssetWriter(fileType: .mp4)` (`SegmentWriter.swift:90`) and hard-linked as `screen.mov` — an **MP4 container with a `.mov` extension and a video track**, which is precisely the input that makes AudioFile's type sniffing fail. Every other consumer in the repo correctly uses `AVURLAsset`; the speech path is the only one that doesn't. The newest, best backend most likely never produces a transcript, and nobody has noticed because nothing tests it and (per docs/11 S3) nobody has run the app.
- **T-C2 · Tidy Speech can silently delete most of a recording.** `TranscriptCutPlanner.silenceCuts` (`:184-217`) has no concept of "a screen recording where narration is one part of the content": narrate for 40 s of a 10-minute capture and it proposes one silence cut from 40.35 s to 600 s. `applying` returns a single clip, the guard `editedDuration > 0` passes, the notice reads **"Removed 1 passage."** — and 94% of the timeline is gone. Undoable, but a user who exports first has lost the work. There is no cap on removed fraction, no confirmation, and **no review list — despite `ProposedCut.label` existing solely to populate one**.
- **T-C3 · Zero timestamps collapse the timeline the same way.** `LegacyTranscriber` trusts `segment.timestamp` unconditionally (`:226-232`). On-device `SFSpeechRecognizer` is known to return `timestamp == 0` for every segment in some configurations; then every word sits at 0, the tail cut runs from 0.35 s to the end, and a 10-minute recording becomes a 0.35-second clip that still passes every guard. One assertion on a synthetic transcript would catch the class.

**HIGH**

- **T-H1 · The wrong audio track is transcribed when the mic is on.** `SegmentWriter` adds system audio first (`:107-114`) and the mic second (`:116-125`); both speech APIs take one stream — in practice the first. Enable the mic to narrate over a playing video and the filler-word cuts are computed against *someone else's speech*. With the mic off (the default) "remove my filler words" transcribes whatever the Mac was playing.
- **T-H2 · Any pause destroys the microphone track.** `SegmentStitcher.swift:54` copies only `loadTracks(withMediaType: .audio).first` into the composition. Record with system audio + mic, pause once, resume, stop → the mic track is silently dropped from the delivered file forever. This is a *recording* bug, not just a speech bug.
- **T-H3 · "Follow my voice"** is implemented: `LiveSpeechFollower` feeds `SpeechFollower`, prefers the recording microphone when one is present, and the Pace slider stays enabled as fallback (docs/16 REC-19).
- **T-H4 · A long transcription is unkillable, unmeasurable, and dies with the window.** `Task { await model.tidySpeech() }` is unstructured and unretained (`StudioInspector.swift:68`); `windowShouldClose` guards only exports. Start Tidy on a 45-minute recording, get an indeterminate spinner with no percentage and no cancel, close the window → torn down mid-recognition. Same for a several-hundred-megabyte model download: no warning, no resume, repeated from zero.
- **T-H5 · macOS 14/15 is a dead end.** `status()` returns `.notApplicable` there, which the inspector folds in with "ready", so the Tidy button shows. If `supportsOnDeviceRecognition` is false — common when the locale's dictation language was never downloaded — the user gets "There is no speech model on this Mac for your language yet" with **no download button and no instruction to enable it in System Settings ▸ Keyboard ▸ Dictation**. A button that always fails, forever.

**MEDIUM:** transcribe-then-refuse (the edited-timeline guard runs *after* minutes of transcription); no transcript caching or persistence (`Transcript` is `Codable` and never encoded — re-running re-transcribes); no `AssetInventory.reserve`/`release`, so a downloaded model can be purged between install and use; word timings on macOS 26 are apportioned by character count and degrade badly if a run lacks `audioTimeRange`; **`Transcribing` is a protocol with no injection point**, which is why the happy path is untested and T-C2/T-C3 went undetected; duplicated guard logic tested via a copy (`refuseTidyIfEditedForTesting`); no language selection anywhere (`Locale.current` only); a possible drain race in `AnalyzerTranscriber` (`async let` before `analyzeSequence`).

### 1.3 Docs vs reality

`docs/03-features.md:153` — "*zero networking code … reaches the network in exactly two places, both enforced by CI*" — is now **accurate and enforced**: `check-layering.sh:69-102` allow-lists `assetInstallationRequest|downloadAndInstall` to `SpeechModelInstaller.swift` only, and CLAUDE.md rule 1 names the exception. Doc 10's governance item is substantially resolved. **Still contradictory:** `docs/02-prd.md:20`, `:85` and `:118` each state Sparkle is the *only* network call. Amend all three.

Also: per CLAUDE.md rule 7 ("every user-visible behaviour must match docs/03"), the entire Tidy Speech feature, the Speech inspector section, the model-download button and the "Follow my voice" toggle are **user-visible behaviour with no spec at all**.

---

## 2. What VoiceInk does — the reference

Four local engines behind **one protocol method** (`transcribe(audioURL:model:context:)`), with cloud providers conforming identically so local and cloud coexist without branching. What matters most for Kadr:

**Model management** — the strongest part. Each model is one immutable record carrying identity (repo + **pinned commit SHA**, not a branch), integrity (`expectedFileSize` + `expectedSHA256`), *and* runtime tuning (chunk seconds, boundary-search seconds, architecture hint). "Is it installed" and "is it intact" become the same query. Downloads are a `URLSessionDataDelegate` writing to a `FileHandle`: `Range` resume, `Content-Range` validation, **restart-not-append when the server ignores Range** (the classic corruption bug, explicitly handled), 3 retries with linear backoff that *keep* the bytes on disk, 0.5% progress throttling with monotonic out-of-order rejection, length check on completion, checksum sidecar written before the final move.

**Model lifecycle** — load requests dedup by *joining the in-flight task*; a static lock serialises the non-cancellable native init; the loaded model's architecture is verified *after* load; retain/release refcounting around each transcription unloads when the count hits zero; three unload triggers including a **memory-pressure `DispatchSource`**, all gated on zero active work.

**Perceived speed** — a speculative model load fires *the moment recording starts*, in parallel with the user speaking, plus prewarm on launch and on system wake (3 s debounce) using a bundled one-second clip. This is the single biggest latency win in the app and costs almost nothing.

**Long audio** — `energyAwareChunks`: split at the **quietest 100 ms window** within the last N seconds of each max-length chunk, no overlap, clamped by the model's own `maxAudioMs`, joined without spaces for ja/yue/zh. ~40 lines, and it avoids cutting mid-word without a VAD model or overlap-dedupe machinery.

**Streaming from a batch model** — `WordAgreementEngine`: normalise (lowercase, strip punctuation) → longest common prefix against the previous pass → require ≥5 common words for 3 consecutive passes → commit only at a **sentence boundary with two sentences of lookahead** → plus a per-word confidence floor at the seam and a per-pass floor. The driver re-runs ASR every second seeded at `hypothesisStartTime`, pads 1 s of trailing silence (which is what makes the model emit terminal punctuation), and **trims confirmed audio out of the ring** so memory and per-pass cost stay bounded regardless of length. Committed text never rewrites itself.

**Robustness** — streaming is a pure optimisation: the WAV is always written, the audio callback returns before the connection completes, and three independent triggers fall back to a full batch pass (including "fewer than 3 segments confirmed → don't trust it"). Errors are a typed taxonomy carrying `recoverySuggestion` and `shouldShowNotification`, so the error type — not the call site — decides whether to bother the user.

**Post-processing** — a 45-line hallucination filter (balanced XML-ish tags via backreference; `[...]`, `(...)`, `{...}` to kill whisper's `[BLANK_AUDIO]`/`(upbeat music)` family; filler words with the orphaned trailing comma; whitespace collapse). Word replacement uses **lookarounds over `[\p{L}\p{M}\p{N}]` minus `\p{scx=Han|Hiragana|Katakana|Hangul|Thai}`** instead of `\b`, with a substring fallback for non-spaced scripts — `\b` is wrong for most of the world. Custom vocabulary deliberately does **not** go into whisper's `initial_prompt` (a known hallucination amplifier); it is applied afterwards.

**UX** — model cards show size, language count, and speed/accuracy as 0–10 dot meters, so users choose sensibly without benchmarks. Language selection can never enter an invalid model/language pairing (`validLanguageOrFallback` rewrites it on model change). Permission steps lock until prior required ones are granted, and because macOS gives no callback for a System Settings toggle, it **polls once a second for 60 seconds** after opening the pane.

**Deliberately not to copy:** the whisper download path (no checksum, no resume, buffered in memory); loading an entire long recording into `[Float]` with no chunking; the absent test suite; and note VoiceInk has **no disk-space precheck** before a multi-gigabyte download — add one.

---

## 3. The plan

Four sprints. T0 is a ship-blocker set that belongs beside doc 11's S0; the rest can follow.

### Sprint T0 — Stop the bleeding (days, not weeks)

- **T0.1 Extract audio properly.** Replace `AVAudioFile(forReading: screenURL)` with `AVAssetReader` + `AVAssetReaderAudioMixOutput` producing **16 kHz mono Float32/Int16 PCM**, selecting the **microphone track when present** and falling back to system audio. This single change fixes T-C1, T-H1 and — by creating a seam — T-M5.
- **T0.2 Make `Transcribing` injectable** and write the tests that were impossible before: a fixture transcript through `tidySpeech` end to end; zero-timestamp transcript (T-C3); narration-then-silence (T-C2).
- **T0.3 Cap and confirm destructive edits.** Refuse (or require explicit confirmation for) any plan removing more than ~40% of the *edited* timeline; sanity-check that the transcript's span bears a relation to `manifest.duration`. Tidy Speech applies after trims by subtracting cuts from the current clip timeline (docs/16 STU-C3).
- **T0.4 Build the review list the data model already assumes.** Render `ProposedCut.label` — "um" at 0:14, "2.3 s pause" at 1:02 — with per-cut toggles and a preview seek, then apply. This is the difference between a feature people trust and one they undo.
- **T0.5 Fix the pause/stitch audio loss (T-H2)** — carry every audio track through `SegmentStitcher`, not just the first.
- **T0.6 Tell the truth about "Follow my voice."** Either restore it (T2.1) or hide the toggle; until then, stop disabling the Pace slider. And add progress + cancellation to both transcription and model download (T-H4), and a System-Settings pointer on the macOS 14/15 dead end (T-H5).

### Sprint T1 — The foundation: a real speech layer

- **T1.1 Move all speech into HelperTools.** Model residency, decode buffers and analyzer state must die with a process — this is docs/04 §7.4, and it is *why* `LiveSpeechFollower` was gutted rather than fixed. The helper already exists, already self-terminates after 30 s idle, and already carries Vision. Give it a speech XPC surface: `transcribe(fileURL, options) -> AsyncStream<TranscriptEvent>` and `startLive(...)` for the prompter.
- **T1.2 One protocol, several engines** — adopt the shape, not the code: a single `transcribe` method, a `RequestContext` carrying language/prompt with a `scoped(to:engine)` choke point that strips options an engine doesn't have, and a registry that picks by availability. Ship `AppleAnalyzer` (26+) and `AppleLegacy` (14/15) behind it on day one.
- **T1.3 Persist the transcript.** `transcript.json` in the `.kadrrec` package, versioned like every other sidecar, with the audio's content hash so it invalidates correctly. This ends re-transcription on every open **and unlocks everything in T2**.
- **T1.4 Progress, cancellation, timeout, signposts** on every speech path — the rule-8 instrumentation a multi-minute operation should have had from the start.
- **T1.5 Model lifecycle done properly:** `AssetInventory.reserve`/`release` so the OS can't purge a model between install and use; a disk-space precheck; unload on memory pressure; and speculative warm-up — start loading the moment the user opens the studio, not when they press the button.
- **T1.6 Language selection**, with the invalid-pairing repair rule: changing engine or model rewrites an unsupported language choice rather than failing later.

### Sprint T2 — The features that beat the reference

Kadr has something VoiceInk structurally cannot: **the transcript is attached to video the user is already editing.**

- **T2.1 Live speech following, restored honestly.** Audio buffers from the agent → helper → word hypotheses back. `SpeechFollower` is already written and tested; it needs a producer. Use the agreement idea in miniature: only advance the prompter on words that survive two consecutive hypotheses, and never scroll backwards on a retraction.
- **T2.2 Captions and subtitles.** Burned-in captions styled with the studio's existing design system, karaoke word highlighting driven by the timings already computed, and **SRT/VTT export**. This is table stakes for a Loom competitor and Kadr is two small steps from it once T1.3 lands.
- **T2.3 Transcript-driven editing, properly.** A transcript panel beside the timeline: click a word to seek, select a sentence to cut it, search the recording by text. The cut planner already exists — this gives it a surface.
- **T2.4 Two-track transcription.** Kadr records system audio and microphone as separate tracks. Transcribing them **separately and labelling them** ("you said" vs "the app said") is genuinely novel for tutorial recording, and impossible for a dictation app.
- **T2.5 Chapter marks** from long pauses plus sentence boundaries — free once T1.3 exists, and exactly what a tutorial recording wants.
- **T2.6 Post-processing worth having:** the bracket/tag hallucination filter, **plus the repetition-loop guard VoiceInk lacks**; filler-word list as data; Unicode-correct word replacement (lookarounds over letter/mark/number classes minus non-spaced scripts, longest-first, substring fallback) so a custom-vocabulary fix works in German and Japanese, not just English.

### Sprint T3 — Beyond Apple's engine (optional, evaluate first)

Apple's on-device engines are free, need no bundle space, and carry no licence risk — but they are opaque, locale-limited, and macOS-version-dependent (T-H5 is a direct consequence). **whisper.cpp is MIT** and would give Kadr one consistent engine across macOS 14–26 with far better language coverage.

The cost is a model download, which the zero-network rule already accommodates through the CI-allow-listed exception pattern. If adopted, implement the download the way the reference does — pinned revision, expected size + SHA-256, resumable with `Range` validation and restart-not-append, retries that keep bytes, checksum sidecar before the final move, progress throttled to 0.5% steps, disk-space precheck — and the load lifecycle likewise: join in-flight loads, verify after load, refcount around use, unload on memory pressure. Ship a small curated ladder (tiny/base/turbo-quantised) with **size, RAM, speed and accuracy shown as data**, not prose. Long audio uses energy-aware chunking at the quietest window rather than fixed offsets.

**Decide T3 on evidence:** measure Apple's on-device accuracy and speed against whisper turbo-q5 on five real Kadr recordings first. If Apple's is close, the extra engine is not worth the bundle, the download and the maintenance.

---

## 4. Definition of done

- Pressing "Tidy speech" on a 10-minute narrated screen recording, with the mic track present, produces a **review list of labelled cuts** the user approves — and never removes 90% of a timeline silently.
- A transcript is produced on macOS 14, 15 and 26; the file handed to the engine is extracted PCM, not a video container; the mic track survives a pause.
- Transcription and model download both show progress and can be cancelled, and neither dies silently when a window closes.
- The transcript is persisted in the session package, re-used on reopen, and exportable as SRT/VTT.
- "Follow my voice" either follows the voice or is not in the UI.
- Speech runs in the helper process; the agent's idle RSS is unchanged and `otool -L` still shows no `Speech` in the agent binary.
- `tidySpeech` has tests that would fail if T-C1, T-C2 or T-C3 were reintroduced.
- The PRD's three "Sparkle is the only network call" statements match the binary and CLAUDE.md.

## 5. The pattern, again

Doc 11 closed on this and the speech audit is the fourth consecutive confirmation: **inside a package this code is excellent; across a seam it is untyped and untested.** `TranscriptCutPlanner` is exemplary; the thing that hands it a transcript opens a video file with an audio API. `SpeechFollower` is exemplary; nothing feeds it. The remedy is the same — an injectable boundary (T0.2), a value that carries its own format (extracted PCM at a stated rate, T0.1), and one test per seam that drives the real producer into the real consumer.
