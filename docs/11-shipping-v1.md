# Shipping v1.0 — What's Next

> Written 2026-08-30 against the post-R tree (469 Swift files, ~73k lines, 1,688 tests, 85 commits). Follows `10-road-to-v1.md`, which has now been implemented. Two independent review passes ran over this tree — a verification pass against every item in doc 10, and a fresh defect hunt that was told nothing about what to expect. **They converged on the same top finding**, which is the strongest signal in this document.
>
> **State of play.** Roughly two-thirds of doc 10 genuinely landed, and the best of it is very good: the clock observer is real and correctly independent of overlay settings; the export `defer` closes every throw path; the `.starting` state is set synchronously before the `Task`; `StudioCore` really was split, the agent really does link only `StudioSession`, and `otool -L` now enforces it; the render plan is cached on `edit` rather than `playhead`; telemetry lookups became O(log n) by binary search (a better trade than the per-frame tables the plan proposed, argued explicitly in the file header); the cache budgets, the lazy coordinators, the lazy Sparkle, the autosave rework and the comment audit are all done. Several fixes ship with structural tests that assert the *wiring* — that the clock observer is installed beside `studio.start(` and not beside the overlays — which is exactly the right instinct.
>
> **And yet the flagship still does not work end to end.** The failure moved rather than closed: from "no cursor at all" to "cursor in the wrong place, twice". Fixing the clock turned on a code path that had been dead, and that path carries a coordinate-space bug. This is the same lesson doc 10 closed on, one axis over — and it is the reason this document leads with structure rather than a patch list.

**Four sprints: S0 ship-blockers → S1 gates → S2 finish → S3 launch.**

---

## 0. The headline: the telemetry seam is mirrored, and doubled

I verified this one by hand rather than trusting the reports, because both passes found it independently and it decides the release.

`Shared.Geometry` documents `ScreenPoint` as *"AppKit's global screen space: origin bottom-left"* and `ScreenRect.pixelPoint` performs the flip `y: (maxY - point.y) * scale.factor`. The event-tap callback passes `event.location` straight into that converter (`PointerTelemetryRecorder.swift:327,331,358`) — but a `CGEvent`'s location is **CG global display space, top-left origin**. The flip cancels: the recorded y comes out as `y·scale` instead of `(H−y)·scale`. An exact vertical mirror. The sibling rungs are correct — `startMonitors` (`:385`) and the sampler (`:441`) both use `NSEvent.mouseLocation`, which really is bottom-left — so **the preferred rung is the broken one** (`TelemetryPolicy.source` returns `.eventTap` first).

Worse, both rungs run. `start()` calls `startEventTap()` *and* `startMonitors()` and then merely *labels* which one won (`:102-109`); nothing tears the loser down. `recordClick` has no rate gate, so one physical mouse-down appends two `ClickEvent`s at the same timestamp — one correct, one mirrored. Two ripples per click, one in the wrong place; pointer samples alternate between `p` and `mirror(p)` with the 1/60 s gate arbitrarily picking whichever arrived first, producing a path that zig-zags across the frame sixty times a second. On a display arranged above the primary, CG y goes negative, `ScreenRect.contains` rejects it, and those samples vanish silently.

Both of these were invisible before this sprint: with a frozen clock the sidecar held exactly one sample. R0.1 succeeded, and success exposed them.

`TelemetryClockTests.swift:25` passes `pointConverter: { $0 }` — an identity function. That is why 1,688 tests miss it, and it is the whole thesis of this document: **nothing in this codebase tests a value crossing a process seam.**

---

## Sprint S0 — Ship-blockers (1–2 weeks)

### S0.1 · Fix the coordinate seam in the type system, not by hand
Convert at the tap boundary — `event.location` is a display point; give `Shared.Geometry` the `DisplayPoint → ScreenPoint` conversion it still lacks, and change `pointConverter` from `(CGPoint) -> CGPoint?` to `(ScreenPoint) -> PixelPoint?` so the mistake stops compiling. This is the point-level wrapper doc 10 R3.5 asked for and only half-delivered: `ScreenRect.pixelPoint` exists and `RecordingCoordinator+Geometry` routes through it, but `WindowSpace.framePoint` still does raw `CGPoint`/`CGRect` arithmetic (`WindowSpace.swift:60-77`) — route it too.
**Done when:** a table-driven test feeds real `CGEvent`-space points through the real converter for (primary display, secondary above, secondary left, 2× scale, 1× scale) and asserts the pixel; the identity converter is gone from `TelemetryClockTests`.

### S0.2 · Install only the rung you use
Tear down the mouse monitor when the tap is live (keep the keystroke monitor unconditionally — the tap mask has no `keyDown`), and add a rate gate to `recordClick`. While there: `TelemetryPolicy.tapSilenceTimeout` is dead, so the documented "watch for a tap macOS disabled and drop a rung" fallback does not exist — implement the downgrade or delete the constant.
**Done when:** a recording with Accessibility granted yields exactly one `ClickEvent` per physical click, and the ladder demonstrably drops a rung when the tap goes silent.

### S0.3 · Close the three recording-lifecycle races
- **`closeSegment` is not reentrancy-safe** (`RecordingEngine.swift:154-165`): `pause()` sets `.paused` then awaits inside `closeSegment()`; `stop()` accepts `.paused` and calls it again on the same writer before `self.writer` is nilled. `accumulatedDuration` is incremented twice with the same segment length and both calls may append the same URL. The user action is ordinary — Pause, then Stop within the ~100–300 ms `finishWriting` window. The inflated duration is written verbatim into `CaptureManifest.duration` and becomes the studio timeline's length, so the playhead scrubs into footage that does not exist. **Fix:** take the writer out of the field before awaiting; add an explicit `.closing` sub-state that `stop`/`resume` await.
- **Cancel-during-start leaves a phantom recording** (`RecordingEngine.swift:112-135` + `RecordingCoordinator.swift:133-181`): `.starting` is `isActive`, so `cancel()` now runs *while* `engine.start` is suspended — it nils the writer, deletes the session and sets `.idle`, then `start` resumes and sets `.recording`. Result: `state == .recording`, `writer == nil`; every frame is dropped, the menu-bar timer counts up, desktop icons stay hidden, and Stop returns `noFramesCaptured`. **Fix:** an epoch token checked after each `await` in `start`, and a `guard state == .starting` in the coordinator's start Task before it claims the recording. *This one was introduced by R0.3* — the fix for double-start opened a stop-during-start hole.
- **Stop-during-`.starting` deletes the session** (`RecordingCoordinator.swift:369-374,414-428`): `stop()` routes to `cancel()`, which synchronously runs `studio.cancel()` → `session.delete()`, while the in-flight start proceeds.

### S0.4 · Make export integrity actually hold
R0.4 closed the throw paths; two doors to the same outcome remain open.
- **A reader failure is reported as success** (`StudioRenderer+Write.swift:66-117`): `copyNextSampleBuffer()` returns `nil` for both "end of track" and "the reader failed", and `reader.reader.status` is never checked. A reader that dies at minute seven exits the loop cleanly, the writer finalises a well-formed 7-minute file, `finished = true`, and `StudioDocumentModel.export` writes a `RenderStamp` blessing it. **Fix:** `guard reader.reader.status == .completed` before `finished = true`.
- **Quitting during an export leaves the partial file** (`EditorAppDelegate.swift:107-109`, `StudioWindowController.swift:80-121`): there is no `applicationShouldTerminate`, no `windowShouldClose` on the studio window, and the progress bar has **no cancel button** — so ⌘W/⌘Q kills the process, the `defer` never runs, and the half-written destination survives. The annotation editor already does this correctly (`EditorWindowController.windowShouldClose:121-147`). **Fix:** hold the export Task on the controller, prompt on close, `.terminateLater` until the render's cleanup ran, and give the user a Cancel button.

### S0.5 · Fix what a reviewer would see in the first five minutes
- **The reconstructed cursor is half-size on every Retina export, with a mis-scaled hotspot** (`StudioFrameComposer.swift:185-206`). `CaptureManifest.scale` is documented as "pixels per point, so the reconstruction draws a cursor the right size", is written as a hard-coded `1` (`StudioSessionRecorder.swift:120-131`) and **read by nothing**. The composer then divides the hotspot by `pixelsPerPoint` believing it arrived in pixels, when the producer wrote points. **Fix:** write the real scale (the engine already has `pointPixelScale`), multiply the drawn size by it, drop the division — hotspot and size share a unit, so the ratio is unit-free.
- **"Show everything" letterboxes to one edge, or crops** (`Reframe.swift:99-112` vs `StudioFrameComposer.swift:113-129`): `.fit` returns the whole source and comments that "the bars are the renderer's business"; the renderer has no bar logic — it scales by width only and never centres. 1920×1080 → 9:16 puts the content flush against the bottom under a 739-px black bar; 1080×1920 → 16:9 **crops**, which is the one thing the control promises not to do. **Fix:** `min(outW/rect.width, outH/rect.height)` and centre.
- **HDR + overlays corrupts pixels** (`FrameCompositor.swift:30-42`): the engine switches to `ARGB2101010LEPacked` for HDR; the compositor hard-codes `bitsPerComponent: 8`. Both are 4 bytes/pixel so `CGContext` *succeeds* and reinterprets 10-bit data as 8888. Two independently-reachable settings in the same pane. **Fix:** branch on the pixel format; refuse loudly on an unknown one.
- **Preview and export disagree about the camera by the whole lip-sync offset** (`StudioPreviewView.swift:113-123`): the export shifts by `cameraStartOffset` (R0.5); the preview seeks the raw `camera.mov` at the screen's source time. The user aligns the bubble against the preview and gets something else. Three separate doc comments assert "the preview *is* the export".
- **`insertCamera` overruns the clip** (`ClipComposition.swift:124-147`): `available` never subtracts the head shift, so the first clip inserts `startOffset` more camera than it holds — and `insertTimeRange` *inserts*, pushing every later segment out. The drift R0.5 fixed on the `elapsed` accumulator survives here.
- **Ripples are sized from the source frame, captions from the output frame** (`StudioFrameComposer.swift:260-263` vs `:299-303`) — after any reframe or crop they disagree by the crop ratio.
- **`cameraStartOffset` is measured from the wrong zero** (`StudioSessionRecorder.swift:64,150-153`): `startedAtUptime` is stamped before `engine.start`, so the offset over-counts by SCK's 200–500 ms setup and R0.5 replaced a +0.3–1.5 s error with a −0.2–0.5 s one. Measure against the first composited frame — the clock observer already fires there.

---

## Sprint S1 — Make the gates real, and green (1 week, run in parallel with S0)

**CI is red on a clean checkout today.** `Scripts/check-layering.sh` fails — not for the reason the first pass reported (see the correction note below), but because it now invokes the dead-API check, which reports nine unallowlisted symbols: `allowsCapture`, `averageConfidence`, `hasAutosave`, `isGestureOpen`, `isUniform`, `needsTransparency`, `prefersDarkText`, `settleNow`, `tapSilenceTimeout`. Each has only its definition in production. The allowlist is honest (3 entries) and is not being used to paper over anything — good discipline — but a red gate that stays red stops being a gate.

Then close the budget stubs. Of doc 10's thirteen proposed gates, six are real and asserting; the rest are declarations. `check-perf.sh` declares editor idle RSS (`:210`) and studio RSS (`:230`) as shell variables and never compares them to a measurement — they only `warn`. The scrub-latency gate builds one composer outside the loop with empty telemetry, so it would have passed *before* R1.1 too. The export-linearity gate uses 4 s vs 10 s rather than minutes, so it cannot see a quadratic. Idle wakeups is still a `sample` grep for `NSTimer`. And three gates are simply absent: agent RSS with the History window open, during a 10-minute recording, and after ten captures.

**The four tests that would have caught this sprint's bugs** — build these first, they are worth more than the budgets:
1. **Event-point → pixel**, table-driven across display arrangements and scales (S0.1). Catches the mirror, and the negative-y drop.
2. **Preview equals export**: render frame *N* through `StudioPreviewRenderer` and through the export loop for the same session+edit; compare pixels. Catches the camera-offset divergence, the `.fit` letterbox and the ripple/caption scale mismatch in one assertion — and the invariant is currently asserted only in prose.
3. **Engine state machine under overlap**, with a fake `SegmentWriter` whose `finish()` is awaitable: pause/stop, cancel/start, resume/pause. No display needed; covers S0.3 entirely.
4. **Export interruption**: a stub reader that returns `nil` with `status == .failed` at frame *k*, plus a full-disk simulation. ~10 lines; covers S0.4.

Also: `FrameCompositorTests` builds only 32BGRA — add the 10-bit format (S0.5), and assert `manifest.scale` round-trips (H1 is invisible from every direction today).

---

## Sprint S2 — Finish what the R-sprints left partial (1–2 weeks)

Ordered by what the next refactor will otherwise re-break.

- **The typed-time distinction was declined.** R0.2 fixed all three sites by rebasing once at each boundary — defensible, well-tested, and it works. But no `SourceTime`/`EditedTime` types were created, so nothing stops the fourth consumer repeating the mistake. C1 is the proof of what that costs on the *space* axis. Build both wrappers now, with `ClipTimeline` as the only bridge; it is the same move that made the flipped-Y bug class uncompilable in M0. Also fix `ClipTimeline.isEdited`, which returns `false` for a tail-trimmed single clip (`InputTelemetry+Rebasing.swift:62-65`), so the fast path keeps telemetry past the trim.
- **`StudioDocumentModel.change()` is docs/07 C2 repeating in the studio.** Every inspector slider tick pushes an undo snapshot *and* writes the draft atomically on the MainActor *and* invalidates the R1.1 cache — so one drag of the Size slider consumes the entire 50-deep undo stack and re-integrates the spring per tick, defeating the cache for exactly the interaction it was built for. The annotation editor learned gesture coalescing in U0.2; give the studio the same `change(coalescingAs:)` plus a debounced `saveDraft`.
- **The clock observer allocates a Task per composited frame** (`RecordingCoordinator.swift:248-254`) — 60 unstructured MainActor hops per second for the length of a recording, on the same actor the event tap runs on, in the process with a 30 MB/0% budget. Ordering between separately-created Tasks is not guaranteed, so `recordingTime` can move backwards and silently drop samples through the 1/60 s gate; and once a minute one of those Tasks performs a synchronous JSON encode of ~3,600 samples on the MainActor. Make `advance` monotonic, coalesce to ~10 Hz through an `AsyncStream` with `.bufferingNewest(1)`, move the journal append off-main.
- **`TelemetryJournal` finalisation undoes its own RAM bound** (`stop()` → `flush(force:)` → `load()` → concatenate → re-encode): for a one-hour recording that is roughly raw JSON + decoded + combined + re-encoded live at once in the agent, a transient spike well past 30 MB at the moment the user presses Stop. Stream the journal into the output encoder instead.
- **Delete the dead window-geometry half.** R3.1 correctly adopted normalise-at-capture, but kept the historical pipeline: `InputTelemetry.windowGeometry` is still collected, copied into the sidecar, rebased on every edit, persisted — and read by nothing. Doc 10 said finish it or delete it; it is now definitively unnecessary. Delete it, and stop walking a dead array on every edit change.
- **`RenderStamp` is written and never read** — `renderStamp()` and `matches(editDigest:pixelSize:)` have zero production callers, so "don't re-render an unchanged edit" does not exist and pressing Export twice re-renders in full. Read it at the top of `export(to:)`. (The dead-API scanner missed it because it keys on bare member names; make it key on `Type.member`, and lift its 8-character minimum and its four-space indent assumption.)
- **The two one-line loose ends are still open.** The teleprompter re-arm is still *inside* the `Task` (`TeleprompterController.swift:184-195`), so dragging the font-size slider still updates once and goes dead — re-arm synchronously inside `onChange` and read `style`/`pacing` as whole units. And `AppDelegate.swift:292` still has `default: break`, so the twelfth command will appear enabled and do nothing.
- **Smaller, all verified:** `SubjectMaskGenerator.swift:87` still builds a fresh `CIContext` per call (the exact defect R2.6 names; two shared statics now exist — consolidate to one). `SessionDocument.commit` deletes the draft its own doc comment promises to keep. The crop sliders are mislabelled — `cropRect.origin.y` is the distance from the **top**, the slider says "Bottom". `StudioPreviewView` retains a full unused copy of the telemetry after the R1.1 refactor. `allURLs` omits `copyMarkerURL`. R1.4's loupe still builds a 1×1 `CGContext` per mouse-move and the badge still runs a full CoreText layout per update; R1.6's vDSP was skipped (defensibly — the greyscale conversion dominates — but say so in the plan rather than leaving the item open).

**One thing to settle with a measurement, not a patch:** `SCStreamFrameInfo.contentRect` is documented by Apple as the content's rect *within the frame* (surface space), while `RecordingEngine+Geometry.swift:20-25` treats it as an on-screen rect and `MovingWindowConverter` does `contentRect.contains(screenPoint)`. If Apple's semantics hold, window-recording clicks are dropped by the `contains` check and the survivors map wrongly. Log `.contentRect` beside `.screenRect` for a window dragged across the screen during one recording; if the origin stays near zero, switch to `.screenRect` (14.0 fallback) and rebuild the `WindowSpaceTests` fixtures, which currently assert the intended semantics rather than SCK's.

---

## Sprint S3 — Launch (2–3 weeks, after S0–S2 are green)

Everything to this point is code correctness. None of it has been validated on a real Mac, because no reviewer in this thread can run the app — every finding in docs 07, 10 and 11 is static analysis. **That is now the biggest unknown, and it is the first item of S3.**

1. **A real-device validation matrix.** Apple Silicon + Intel; macOS 14, 15 and 26; single display, mixed-DPI dual display, external display above the primary, hot-unplug mid-capture; sleep/wake during a recording; a 60-minute recording; a 5K capture; a full disk; permission denied, then granted, then revoked mid-use. Write it down as a checklist and run it every release — most of this sprint's CRITICALs are things a human would catch in ten minutes with a screen recorder and would never catch by reading.
2. **Resolve the network-rule contradiction — it is a promise, not a bug.** `SpeechModelInstaller` still calls `AssetInventory.downloadAndInstall`; `CLAUDE.md` rule 1 still says Sparkle is the only exception; `check-layering.sh`'s `NETWORK_SYMBOLS` still omits the symbols; `docs/03-features.md:207` still advertises "no model download". This was doc 10's cheapest item and it is untouched. Pick one and make all four agree — amend the rule with a named, path-allow-listed exception *and* extend the grep, or drop the installer and let macOS install the model in System Settings. A local-first product cannot ship with its own rule file contradicting its binary.
3. **Beta program.** A public TestFlight-equivalent channel (Sparkle supports a beta appcast), a crash-reporting story that respects zero-telemetry (a user-initiated "send this crash log" flow, never automatic), and a feedback path that does not require an account.
4. **The things a v1.0 is judged on that no reviewer has looked at yet:** VoiceOver over the editor and studio, full keyboard operation of the timeline, reduced-motion, localization readiness (the String Catalogs exist — are the new U/R-sprint strings in them?), and a first-run experience for the studio specifically (the onboarding predates it).
5. **The launch surface:** a README that shows the studio, a site or GitHub Pages with the performance numbers the CI harness now produces, the Homebrew cask, and the honest positioning — free, local-only, no account, drag-and-drop sharing — against CleanShot's $29+subscription, Screendrop's macOS 26 floor and Loom's cloud dependency.

---

## Correction to the previous review, and one to this one

Two things in the verification pass were artifacts of **my** staging, not defects in your repo, and I want them corrected in the record rather than buried:

- **`Kadr.xcodeproj`, `Kadr.xcworkspace` and `Resources/KadrEditor-Info.plist` all exist.** I excluded them from the archive I reviewed, which made the layering check's project parsing look broken and made `InfoPlistTests` look like it referenced missing files. Running `check-layering.sh` against the real tree confirms the linkage checks pass. **R3.5's Info.plist item landed correctly** — the three usage strings are in the build settings and `CFBundleDocumentTypes` is in the editor's plist, so that row should read VERIFIED FIXED, not NOT FIXED.
- **CI is still red**, but for the dead-API check (nine symbols), not the project file. That is a real, fixable finding — S1 item one.

Doc 10's own R0.2 recommendation was **declined** in favour of a rebase-at-the-boundary approach. That was a reasonable engineering call and it is well-tested. I am recording it here because C1 is the counterfactual: the plan argued for types precisely so that the *next* consumer could not repeat the mistake, and the next consumer promptly did, one axis over. Read S2's first item in that light.

---

## The pattern, stated once more, because it has now held across three reviews

Inside a package, this codebase is exemplary — pure value types, table-driven tests, comments that explain reasoning, and, increasingly, structural tests that assert the wiring rather than the behaviour. **Across a seam it has no types, no tests and no compiler checks**, and every serious defect in three consecutive reviews has lived there:

- docs/07: a drag whose file URL was stale by the time the receiver read it.
- docs/10: a `TimeInterval` nobody set; two `TimeInterval`s that meant different things and shared a type; an offset nobody recorded.
- docs/11: a `CGPoint` that means two different things; a state set before an `await`; a manifest field written as `1` and read by nobody; a preview and an export that disagree.

The remedy is not more review. It is three habits: **(1)** values that cross a process or module boundary get a type that encodes their space, their clock or their unit — `ScreenPoint`/`PixelPoint` proved this works, and `SourceTime`/`EditedTime`/`DisplayPoint` are the missing siblings; **(2)** every seam gets one test that drives the real producer into the real consumer, even when the middle is faked; **(3)** an invariant asserted in a doc comment is either enforced by a test or deleted from the comment — "the preview *is* the export" appears three times in prose and zero times in the test suite.

## v1.0 definition of done (updated)

- A 10-minute studio recording, made with Accessibility granted, on a Retina display, with a cut and a speed change, exports with: a correctly-positioned full-size cursor, one ripple per click at the right place and time, captions and ripples at consistent scale after a reframe, a lip-synced camera bubble, and `.fit` that actually shows everything.
- Pause-then-stop, stop-during-start, and quit-during-export all do the obvious thing and never leave a truncated file or a phantom recording.
- `make check` is green: layering, dead-API, size, and a perf harness whose editor/studio budgets are assertions rather than warnings.
- The four seam tests exist and would fail if S0's bugs were reintroduced.
- CLAUDE.md rule 1, the CI grep, `docs/03` and the shipping binary agree about the network.
- The real-device matrix has been run once, end to end, by a human.
