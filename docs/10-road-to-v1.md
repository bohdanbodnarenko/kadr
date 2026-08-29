# Road to v1.0 — What's Next

> Written 2026-08-29 against the post-U3 tree (448 Swift files, ~70k lines, 1,609 tests, 73 commits). Supersedes the "what's next" sections of `06-implementation-guide.md` and `09-uplift-plan.md`; both of those are now history — every milestone they define has an implementation.
>
> **The state of play in one paragraph.** The architecture held through a doubling of the codebase: the three-process split, the package layering, SCK-only capture, the CALayer mouse path, the geometry wrappers and the zero-timer idle discipline all survived, and the U0 fixes from `07-code-review-2026-08.md` are genuinely landed (C1–C3, H3–H5, M4 all verified closed). Inside a package this code is exemplary — pure types, table-driven tests, comments that explain reasoning. **What did not scale is discipline at process seams**, and that is where every serious defect now lives: the agent writes a telemetry file, the editor reads it, and nothing types, tests or compiles that boundary. The flagship U3 studio consequently does not work end to end. Fixing that, and then making the app as fast and as small as its own budgets claim, is the whole of v1.0.

**Four sprints, in strict order: R0 correct → R1 fast → R2 lean → R3 delightful.** Work them like docs/06 milestones — one per branch, read the cited files first, verify the Done-when list.

---

## 0. The headline: the studio's telemetry chain is inert

`Kadr/Recording/PointerTelemetryRecorder.swift:52,115-117` — `recordingTime` is documented as *"Set by the engine as it composites, so the sidecar and the footage share one clock."* It is set in exactly two places: `= 0` in `start()`, and by `advance(to:)`, whose **only production caller is `RecordingCoordinator.resume()`**. Nothing else moves the clock.

The consequences cascade through everything U3.1–U3.3 built:

1. Every `ClickEvent` and `KeystrokeEvent` in `input.json` carries `time: 0`.
2. `TelemetryPolicy.shouldRecord` gates on `time - lastSample.time >= 1/sampleRate`; with a frozen clock that is `0 >= 1/60` → false forever. **`input.json` contains exactly one pointer sample.**
3. `InputTelemetry.duration` is 0 → the reconstructed cursor is a stationary dot; every click clusters into one zoom cue at 0:00; every keystroke caption fires in the first 1.4 s.

So: record a 3-minute demo with studio capture and cursor reconstruction on — which sets `showsCursor = false` — and you get footage with **no cursor at all**, no ripples, no captions, and "Add smart zooms" produces a single zoom at the start. The one feature that beats Loom and matches Screen Studio is, today, a no-op that also removes the real cursor.

The correct clock already exists and a sibling already consumes it: `RecordingEngine.swift:349` publishes `accumulatedDuration + elapsed` to the overlay provider on every composited frame, and `RecordingOverlaySource` latches it. The studio recorder simply never got the feed — and `RecordingCoordinator.startOverlays` returns early (`:176-179`) whenever the user has no overlays enabled, which is exactly the studio-capture case.

No test caught it because `KadrTests/StudioSessionRecorderTests.swift:8-14` declares telemetry capture out of scope ("needs an event tap and a real pointer"). True of the tap; false of the clock, which is an integer with a setter.

---

## Sprint R0 — Make the flagship real (1–2 weeks, blocks everything)

### R0.1 · Feed the studio recorder the engine clock *(fixes the above)*
Publish the recording clock through a dedicated channel rather than the overlay-drawing API — add `RecordingEngine.setClockObserver(_:)` beside the existing `setGeometryObserver`, and have `RecordingCoordinator` install it whenever `capturesStudioSession` is true, independent of overlay settings. Amend the early return at `RecordingCoordinator.swift:176` so a studio capture always gets a provider.
**Done when:** a driven test (`advance(to: 1.0)` → record → `advance(to: 2.0)` → record) yields two samples with distinct times; an integration test records 5 s with *no* overlays enabled and asserts `input.json` holds ≥ 250 pointer samples spanning ≥ 4.5 s; a rendered export shows a moving cursor.

### R0.2 · Make source-time and edited-time distinct types *(fixes three silent conversions)*
`ClipTimeline` says it is *"the one place that converts between them"* — three consumers never call it:
- `StudioFrameComposer.swift:50,147,278` draws telemetry at **source** times against an **edited** playhead. Cut 10 s from the middle and every ripple and caption after the cut fires against the wrong footage; set 2× and the cursor plays at half the picture's speed.
- `StudioDocumentModel.planSmartZooms` (`:187-196`) plans cues from source-time clicks and stores them into `StudioEdit.zooms`, documented as edited time. `ClipTimeline.rebasing(_ cues:)` exists for exactly this and **has no caller outside tests**.
- `tidySpeech` (`:355`) measures a source-time transcript against `edit.duration` (edited) and then calls `applying`, which **rebuilds the timeline from scratch at speed 1** — record 60 s, set 2×, press Tidy speech, and your speed change is gone and the tail is silently deleted.

The fix is the same move that made the flipped-Y bug class uncompilable in M0: give `Shared`/`StudioCore` a `SourceTime` and an `EditedTime` wrapper, make `ClipTimeline` the only bridge, and let the compiler find the rest. Rebase telemetry once in `StudioFrameComposer.init` so preview and export share it by construction.
**Done when:** all three sites go through the bridge; a test cuts 10 s from the middle and asserts a click ripple lands at the correct *edited* time; `tidySpeech` on a 2×-speed timeline preserves the speed or refuses with a notice.

### R0.3 · Recording start is re-entrant and self-destructive
`RecordingCoordinator.swift:102-163` sets `state = .recording` only *after* `await engine.start(...)` — a 200–500 ms window during which `isRecording` is false and the menu items stay enabled. A second hotkey press lands in the catch block and runs `stopOverlays()`, **`studio.cancel()` (which deletes the session directory)**, `stopGeometryObserver()`, `teleprompter.stop()` and `hygiene?.endRecording()` — all against the *first, still-running* recording. The user keeps recording with overlays gone and desktop icons back, and gets no studio session at the end. Add a `.starting` state set synchronously before the Task and included in `isRecording`.
**Done when:** calling `beginDisplayRecording()` twice without awaiting produces one session and one engine start.

### R0.4 · Export failure leaves a truncated file at the user's path
`StudioRenderer+Write.swift:24-91` removes the destination up front, then every throw path (cancellation, `waitUntilReady`, `append`, `drainAudio`) exits without `cancelReading()`/`cancelWriting()` and leaves a partial `.mov` behind. Disk fills at 70% → the studio says "export failed" and Finder shows a file that plays for seven minutes. Add a `finished` flag with a `defer` that cancels both and removes the destination.
**Done when:** cancelling mid-render leaves no file at the destination; a disk-full simulation likewise.

### R0.5 · The camera bubble is permanently lip-sync offset
`CameraFileRecorder.swift:98-122` starts the capture session and the file output back to back; the first camera frame lands 0.3–1.5 s later (longer on external UVC). `ClipCompositionBuilder.insertCamera` aligns camera source-time 0 to screen source-time 0, and `CaptureManifest` has **no field for the offset** — so the error can never be corrected in the editor because it was never measured. Record the real start in `fileOutput(_:didStartRecordingTo:)`, persist `CaptureManifest.cameraStartOffset`, bias `insertCamera` by it. While there, fix the drift at `ClipComposition.swift:133` (`elapsed += available / clip.speed` advances by the truncated length, shifting every later segment early).
**Done when:** a synthetic session with a 1 s camera delay composites in sync; a composition test asserts segment starts are unaffected by a short camera file.

---

## Sprint R1 — The performance program (1–2 weeks)

Two algorithmic defects dominate everything else in the studio. Both are small fixes with large multipliers.

### R1.1 · Cache the render plan across scrub ticks
`StudioPreviewView.swift:45,51` uses `.task(id: model.playhead)`, so **every scrub event** builds a fresh `StudioRenderPlan` — whose `init` integrates a spring at 240 Hz across the whole recording — and a fresh `StudioFrameComposer`, which integrates again and re-decodes every cursor PNG (despite a comment claiming "decoded once"). For a 10-minute recording that is ~288,000 spring evaluations and ~4.6 MB of allocation **per mouse-move**, on the main actor; for an hour, 1.7 M steps and ~28 MB. The timeline cannot help but lock up.
Hold both in `@State`, rebuild only on `.task(id: model.edit)` (`StudioEdit` is already `Hashable`). **~15 lines — the single highest-leverage change in the codebase.**
**Done when:** a scrub-latency test on a 10-minute session asserts < 50 ms playhead → composed frame.

### R1.2 · Make per-frame telemetry lookup O(1)
`CursorReconstruction.swift:92-93,127` and `StudioFrameComposer.swift:278` use `last(where:)` — which scans *backwards from the end* — plus a full `filter` with a fresh array allocation per frame, while render time advances monotonically from 0. At 60 Hz telemetry and 60 fps over 10 minutes that is ≈ 6.5 × 10⁸ predicate evaluations for cursor lookup alone, growing quadratically with duration. Precompute `cursorIndexPerFrame`, `pressPerFrame` and `captionPerFrame` in one forward merge pass in `init`; `frame(at:)` becomes index math. O(N·F) → O(N+F).
**Done when:** an export-throughput test asserts ≥ 1.5× realtime for 1080p60 and **linearity** (`t(10 min) < 2.5 × t(4 min)`); a composer test asserts per-frame cost grows < 20% between 1k and 100k telemetry samples.

### R1.3 · Stop PNG-encoding the cursor 60×/s on the main actor
`PointerTelemetryRecorder.swift:129,162-180` runs TIFF-encode → bitmap-decode → PNG-encode → hash the full `Data` on **every** pointer sample, on `@MainActor`, inside the event-tap path macOS will disable if it runs long — for a cursor that changes maybe twenty times a session. Estimated 1.2–3% of a core continuously plus 1–2 MB/s of allocation churn. Key the dedupe on cheap identity first (`ObjectIdentifier(NSCursor.currentSystem)`, or size + hotspot + byte count) and encode only on a genuine miss.
**Done when:** a benchmark asserts < 20 µs per sample in the steady state.

### R1.4 · Take the layout out of the 120 Hz paths
`SelectionOverlayView.swift:393-396` allocates an `NSAttributedString` and runs a full CoreText `.size()` layout on every `mouseMoved`/`mouseDragged` for the dimension badge, plus a font lookup and a `CATextLayer.string` re-rasterisation. Hoist the font to a `static let`, compute width from monospaced-digit advance × count, and skip the update when the formatted text is unchanged. Same sprint: `LoupeSampler.color(at:)` builds a 1×1 `CGContext` per mouse-move (`:64-81`) — read the pixel from the frozen image's data provider instead.

### R1.5 · Move the expensive editor renders off the main actor
The settle-preview pattern **is** correctly implemented (verified: `mouseDragged` touches only the draft layer), but when the settle fires, `AnnotationCanvasView+Chrome.swift:60-69` runs the full export renderer inline on `@MainActor` over the whole 5K canvas — a 100–300 ms stall on every slider release. Move it to a detached task and assign `cameraLayer.contents` on completion; the stretched preview already on screen is exactly the right thing to show meanwhile.
*While there:* with a camera or progressive blur active, `mouseUp` → `rebuildAnnotationLayers()` never calls `updateExpensiveChrome()` and `contentHost` is hidden — so newly drawn annotations appear not to render until something else triggers a chrome layout. Verify and fix.

### R1.6 · Make edge detection lazy
`SelectionOverlayController.swift:245-267` runs full-resolution edge detection after **every** overlay present, per display, whether or not the user ever drags near an edge — a 14.7 MB grayscale buffer plus a 14.7 M-iteration scalar loop for a 5K display. Move it to the first `mouseDown` and vectorise the luminance pass with vDSP (`Accelerate` is already imported in `Shared`).

---

## Sprint R2 — The memory program (1–2 weeks)

Idle discipline in the agent is structurally excellent — **zero timers, zero Combine, zero leaked observers, zero retained full-res bitmaps**, correct `NSHostingView` teardown, an XPC client that always disconnects. The regressions are all recent and all fixable.

### R2.1 · Get Speech, AVFoundation and CoreImage out of the agent *(the biggest idle win)*
The agent imports `StudioCore` from 12 files, and `StudioCore` is one target holding both agent-side capture models (`InputTelemetry`, `RecordingSession`, `TelemetryPolicy`) **and** the whole render pipeline (`StudioRenderer`, `StudioFrameComposer`, a `CIContext` singleton) plus `Transcriber`/`SpeechModelInstaller`. Every user who never records pays dyld mapping and dirty pages for Speech.framework and the CoreImage/Metal stack at every launch: **+4–8 MB idle RSS and +20–60 ms cold launch** against 30 MB and 300 ms budgets.

Split into `StudioSession` (layer 2, Foundation/CoreGraphics, agent-linkable) and `StudioRender` (layer 2, editor-only), add `StudioRender` to `FORBIDDEN_IN_AGENT`, and add the check that actually holds the line: **`otool -L` on the agent binary must not list `Speech`, `CoreImage`, `VideoToolbox` or `Vision`.**

### R2.2 · Undo the accidental eager initialisation
`AppDelegate.connectCaptureCallbacks()` (`:213` → `:122-149`) assigns callbacks on four `lazy var`s and therefore **builds them all at launch** — `RecordingCoordinator` (engine actor, compositor, stitcher, focus mode, overlay source, studio recorder, pointer recorder, camera recorder, geometry tracker) and `ScrollCaptureCoordinator` (Vision client, session, auto-scroller, preview strip) — leaving three `SelectionOverlayController` instances resident at idle instead of zero. The file already documents the opposite intent and hand-writes `areaCaptureStorage` (`:52-63`) precisely to avoid this. Invert the wiring: inject a delivery object, or store the closures and assign them inside the accessor. This is also the prerequisite for R2.1's guarantee being *provable*.

### R2.3 · Make Sparkle lazy
`AppDelegate.swift:104` holds `UpdaterManager.shared` as a stored `let`, so `SPUStandardUpdaterController` is constructed and Sparkle.framework loaded **before `app.run()`**; in release `start()` then registers Sparkle's own repeating check — so "zero timers, zero wakeups at idle" is not true of shipping builds, and `check-perf.sh`'s 60-second CPU sample cannot see a daily timer. Make it `lazy`, construct inside `start()` after the launch interval closes, cancel the stray 120 s backstop task in `releaseCheckWaiters()` (`UpdaterManager.swift:78-82`), and either amend the PRD wording or move the check to `NSBackgroundActivityScheduler` so the OS coalesces it.

### R2.4 · Re-budget the caches
- `ThumbnailCache` allows **16 MB — 53% of the entire agent target** (`ThumbnailCache.swift:20`), and only the History *window* purges it; the menu strip writes into the same cache and nothing ever clears it. Drop to 6 MB, purge strip entries in `menuDidClose`, and give the strip its own small sub-budget so grid churn can't evict it.
- `WallpaperCache` allows **192 MB** with buckets up to 8192 px (one 4096 entry = 67 MB) and — unlike `ThumbnailCache` — has **no memory-pressure source** and no caller for `removeAll()`. Drop to 48 MB, clamp buckets to 4096, copy the pressure `DispatchSource` across.
- `ImageCache` (`ImageRendering.swift:43-52`) is bounded by **count (16), not bytes** — worst case 16 × 59 MB ≈ 944 MB — and keys on `data.hashValue`, which on Darwin hashes a bounded prefix and **returns the hit without verifying the bytes**, so two same-length PNGs with identical headers can return the wrong image. Bound by bytes; key on SHA-256 (CryptoKit is already a dependency).

### R2.5 · Bound the telemetry arrays and the smoothing tables
Pointer/click/keystroke arrays grow unbounded in the agent for the length of a recording — 2.4 KB/s → **8.6 MB after an hour**, with a transient 17 MB spike at the array-doubling. `reserveCapacity` on start and flush to the sidecar in append-only chunks every ~60 s. Related, in the editor: `ViewportTimeline` and `CursorReconstruction.path` each store 240 Hz tables — ~35 MB of tables for a 1-hour recording before a frame is decoded. Consider 120 Hz or windowed integration once long-form recording is a real use case.

### R2.6 · Share one CIContext; stop re-encoding on autosave
`RedactionRasterizer.swift:38` and `SubjectLiftCompositor.swift:30` build a fresh `CIContext` per call (each compiles Metal pipelines: ~50–150 ms and 10–40 MB) while two siblings correctly share statics — the editor ends up with four process-wide contexts. Consolidate on one `KadrRenderContext.shared`. Separately, editor autosave (`EditorWindowController.swift:201-211`) re-encodes the **immutable** base image to PNG every 1.5 s and CRCs the whole archive with a byte-at-a-time pure-Swift `crc32` on the main actor — tens of millions of iterations for a 5K capture, worse now that M24 embeds images as base64. Cache the base PNG at open, move the write off-main, use a table-driven CRC.

### R2.7 · Close the CI budget gaps *(this is what stops R1/R2 regressing)*
`check-perf.sh` measures **only the agent**, and only three of the eight PRD §8 budgets — while the memory risk has moved almost entirely into the editor. Two harness bugs make it worse than that: `check-layering.sh`'s **check B parses `Kadr.xcodeproj/project.pbxproj`, and when that file isn't found it silently falls through and prints a pass** — the linkage guarantee is currently unenforced at the link level; and `endLaunchInterval()` (`AppDelegate.swift:191`) closes the cold-launch signpost *before* hotkey registration, Sparkle, the automation port, both sweeps, history open and hygiene — so the measured 300 ms excludes everything expensive, including the moment the app can first answer a hotkey.

| New gate | Budget | Where |
|---|---|---|
| Agent framework denylist | no `Speech`/`CoreImage`/`VideoToolbox`/`Vision` in `otool -L` | `check-layering.sh` |
| Layering check B | **fail loudly** when the pbxproj is missing | `check-layering.sh` |
| `launchToHotkeyArmed` | < 300 ms (keep `launchToStatusItem` < 150 ms) | signpost + harness |
| Editor idle RSS (5K capture open) | < 120 MB warn / 180 fail | `check-perf.sh --editor` |
| Editor exits after last window | process gone < 2 s | UI test |
| Studio RSS (10-min session, scrubbed) | < 250 MB / 350 fail | `check-perf.sh --studio` |
| Studio scrub latency | < 50 ms | `EditorUITests` — catches R1.1 |
| Studio export throughput + linearity | ≥ 1.5× realtime; `t(10m) < 2.5·t(4m)` | pure Swift test — catches R1.2 |
| Composer per-frame O(1) in telemetry size | < 20% growth 1k → 100k samples | `StudioCoreTests` |
| Agent RSS with History window open | < 30 MB | catches R2.4 |
| Agent RSS during a 10-min recording | < 60 MB | catches R1.3/R2.5 |
| Agent RSS after 10 captures + editor closed | back < 60 MB in 30 s (in PRD §8, never implemented) | scripted |
| Idle wakeups | real wakeup count, not a CPU-delta proxy | `powermetrics`/`sample` |

---

## Sprint R3 — Delight: finish, prune, and out-edit the field (2–3 weeks)

### R3.1 · Finish the window-geometry feature — Screendrop's way
`InputTelemetry.windowGeometry` is **write-only**: captured, persisted to `capture.json`, decoded back, and **read by nothing**. The whole pipeline (`WindowGeometryTracker.frame(at:)`, `WindowGeometrySample`, `noteGeometry`) exists to serve the U3.1 promise that a zoom stays anchored to a button rather than to a screen position the button has since left — and the studio never asks.

Screendrop shipped a fix for exactly this bug this month ("Fix click positions in window recordings"), and their answer is better than ours: they **normalise at capture time**, not at render time. `RecordingPointerCapture.normalizedPoint(for:at:mapping:)` maps the screen point through the window's `screenRect` in force at that instant, then through the `contentRect` the window occupies inside the fixed output surface (binary-searching a geometry array by uptime) — so the sidecar stores already-correct normalised coordinates and no consumer has to know windows move. Their comment explains why the second hop matters: once a window is resized, SCK scales content down and pins it to the surface's top-left rather than refitting the surface.

Adopt that shape: normalise in `PointerTelemetryRecorder` using the geometry sample in force, and the dead lookup disappears along with the correctness bug. **If you decline, delete the whole pipeline (~60 lines) rather than leave a captured-but-unread sidecar field.**

### R3.2 · Make `CaptureExclusionRegistry` real or delete it
`excludedWindowIDs` (`CaptureExclusion.swift:52`) has **no production consumer** — every filter still excludes the whole application. U2.1's "formalize the capture-exclusion registry" is unfulfilled and the file's own doc comment describes behaviour that does not exist (it claims you can now screenshot Kadr's Settings window to file a bug; you cannot). Either thread it into `SCContentFilter(display:excludingWindows:)` via the shareable-content window lookup, or delete it and correct the comment.

### R3.3 · Prune the dead API, and treat it as a bug marker
Twenty-five symbols have tests but no production caller. The pattern is consistent and worth naming: **almost every one is a helper written for a consumer that was then implemented differently** — `ClipTimeline.rebasing` vs `planSmartZooms`, `ClipTimeline.setSpeed` (which clamps 1…8) vs `setSpeedAtPlayhead` (which writes the plain `var` and can produce a negative `editedDuration`), `excludedWindowIDs` vs whole-app exclusion, `AfterCaptureMatrix.legacyAction` vs direct reads. **In three of those cases the dead helper was the correct implementation and the ad-hoc one is a bug** (R0.2, the speed clamp, R3.2). Add a CI check for "public API with tests but no production caller" — here it is a reliable defect detector, not merely clutter.
Delete outright: `ArrowBindingResolver.isBound`, `ArrowSpec.isCurved`, `CaptureOutput.deliverOffMain(_ captures:)`, `TelemetrySource.limitation`/`capturesClicks`, `SessionDocument.committedEdit`, `StudioDocumentModel.isExportUpToDate`, `SpeechModelInstaller.Status.canInstall`/`isReady`, `EditorDocumentModel.insertedImages`, `StudioSessionRecorder.startedAt`, the no-op `@ObservationIgnored` at `StudioSessionRecorder.swift:85`, `MeasureSpec.isAxisAligned`, `AnnotationTool.isPointerTool`, `HistoryPolicy.keepForever`. Wire or delete: `bringForward`/`sendBackward` (no shortcut binds them), `ProgressiveBlurSpec.obscureCentre` (never offered in the UI), `AnnotationDocument.isGestureOpen` (its comment claims the canvas consults it for the 60 fps gate — it doesn't; check whether it should).

### R3.4 · Audit comments that outrun their code
Six doc comments assert behaviour that does not exist — `CaptureExclusion.swift:8-15`, `PointerTelemetryRecorder.swift:49-51`, `AnnotationDocument.swift:195-196`, `RecordingCoordinator.swift:253` ("goes through `Shared.Geometry` rather than ad-hoc arithmetic", above a raw `(frame.maxY - point.y) * scale`), `ZipArchive.swift:9-10`, `StudioFrameComposer.swift:51`. Every one marks a place where the reasoning was written and the wiring was never finished. **Treat a comment that outruns its code as a defect**; this list is the best available map of the next round of bugs.

### R3.5 · Close the last real gaps vs the field
Everything below is small, and with it Kadr is feature-complete against all three references:
- **Free video crop** in the studio — Screendrop shipped non-destructive video cropping this month (`videoCropRect` + `RecordingVideoCropGeometry`); we have aspect reframe but no arbitrary crop rect.
- **Portable preset files** — their `AnnotationBackgroundPresetTransfer` defines a versioned, size-capped, *path-free* preset document (deliberately not reusing the storage model, so a shared preset cannot reference a local wallpaper). Our `StylePreset` has no transfer format. A `.kadrpreset` UTType is a day's work and makes presets shareable — the kind of thing that spreads a tool.
- **Point-level geometry wrapper** — rule 6 has a hole: there is no typed `ScreenPoint → PixelPoint` flip, so the two most safety-critical new conversions (`RecordingCoordinator.pointConverter:254-295` and `WindowSpace.framePoint`) are both hand-rolled. Add the helper; route both through it.
- **Info.plist verification** — three new TCC-gated APIs landed (`SFSpeechRecognizer.requestAuthorization` ×2, `AVCaptureDevice.requestAccess(for: .video)`); a missing `NSSpeechRecognitionUsageDescription`/`NSCameraUsageDescription` is a hard crash on first use, and docs/04 §10 still lists only the microphone key. U1.8's import-from-Finder also needs `CFBundleDocumentTypes`, which nothing in the repo declares. Add a test that reads `Bundle.main.infoDictionary` for every required key.
- Smaller: `RenderStamp.digest` returns `""` on encode failure and `matches` compares equality — two failed encodes collide into a cache hit, the exact "wrong file shipped" outcome the type exists to prevent (return `nil`, treat as a miss). `pause()` reports success even when the engine refuses (`try?` at `RecordingCoordinator.swift:330`). Live speech following dies silently when the recogniser's task ends and never restarts. `tidySpeech` can produce a zero-clip timeline that then fails to export. Cross-volume sessions are never swept, so every recording saved to an external disk keeps a full second copy in Application Support forever.

---

## The four loose ends you flagged — verified, with corrections

I checked each against the tree. **Two of the three "dead API" premises are wrong, and the real dead thing is bigger than described.**

| Your item | Finding |
|---|---|
| `InputTelemetry.windowFrame(at:)` has no callers | **No such symbol exists** (`grep -rn windowFrame` → 0 hits). You're thinking of `WindowGeometryTracker.frame(at:)` (`Kadr/Recording/WindowGeometryTracker.swift:40-42`) — and that one *is* dead, zero callers anywhere. |
| `windowMoved` has no callers | **No such symbol exists.** The live neighbour is `StudioSessionRecorder.noteGeometry(_:at:)`, called from `RecordingCoordinator.swift:229`. |
| `TeleprompterScript.progress(atWord:)` has no callers | **False — it is called in production** at `TeleprompterScriptView.swift:152`, where it draws the prompter's progress bar. The feature you were about to build already exists. Leave it. |
| Real finding | The dead thing is a **whole feature, not a method**: `InputTelemetry.windowGeometry` is write-only end to end. See R3.1 — finish it Screendrop's way or delete ~60 lines. Note `MovingWindowConverter` in the same file is *live* and different; only the historical `samples`/`frame(at:)` half is dead. |
| `CaptureCommand.isAvailable` always returns `true` | **This symbol does not exist and never did.** `Kadr/Commands/CaptureCommand.swift` (61 lines) declares only `title`, `shortcutTitle`, `menuCommands`, `utilityCommands`, `recordingCommands`. All nine `isAvailable` hits in the tree are elsewhere and all correct (`EditorLauncher` checks the embedded bundle; `DynamicRange`/`DocumentTableRecognizer` are genuine OS-version gates). **The nearest real instance of the hazard you describe:** `StatusItemController.swift:84` sets `menu.autoenablesItems = false`, so items default to enabled and only two ever set state explicitly. I traced all eleven `CaptureCommand` cases through `AppDelegate.perform` — all eleven are implemented, so the menu is honest today. The latent risk is `default: break` at `AppDelegate.swift:277`: the *next* command added will appear enabled and do nothing. **Fix: drop the `default:` so the switch is exhaustive and the compiler catches it.** |
| Teleprompter appearance doesn't reach the panel mid-recording | **Confirmed — and the cause is ordering, not a missing wire.** The whole path exists and is correct (Settings → `onChange` → `syncFromSettings()` → `panel.style` → `didSet` → redraw). The break is at `TeleprompterController.swift:184-196`: `withObservationTracking` fires **once** and must be re-armed, and the re-arm happens *inside* `Task { @MainActor … }`, i.e. on a later turn — but the tracking closure is what registers the observations. SwiftUI drives a slider with repeated writes in one run-loop pass, so write 1 fires `onChange` and schedules the re-arm, writes 2…N arrive **unobserved**, then the re-arm reads the final value. Net effect: toggling Mirrored (one discrete write) works; *dragging* the font-size slider updates once and then goes dead. **Fix: re-arm synchronously inside `onChange`, before hopping** — keep only the read deferred (it must be: `onChange` fires on `willSet`, before the new value is stored). Belt and braces: have `arm` read `style` and `pacing` as whole units rather than listing three keys, so a fourth appearance setting can't be added unobserved. `TeleprompterTests` already has the seams (`isShowing`, `scrollOffsetForTesting`) — add: three writes in one turn, await a hop, assert the panel took the last value. |

---

## Two decisions that need you, not a patch

**1. The zero-network rule now has a second exception.** `SpeechModelInstaller.swift:96-105` calls `AssetInventory.assetInstallationRequest(...).downloadAndInstall()`. The engineering is careful — user-initiated, cancellable, and `Transcriber.swift:105-113` refuses anything but `.installed` precisely so `SpeechAnalyzer` can't fetch implicitly, with a test that greps the source to enforce it. But: CLAUDE.md rule 1 still says Sparkle is the *only* exception; `check-layering.sh`'s `NETWORK_SYMBOLS` doesn't include `AssetInventory|downloadAndInstall`, so the machine-verified promise silently stopped covering the thing it exists to cover; and `docs/03-features.md:207` still sells "no model download". Pick one: amend rule 1 with a named, path-allow-listed exception **and** add the symbols to the CI grep, or drop the installer and let macOS 26 users install the model in System Settings (the code already handles `.available` gracefully). The current state — a rule that says one thing and a codebase that does another — is the only outcome that isn't defensible.

**2. The teleprompter runs a speech recogniser inside the agent.** `LiveSpeechFollower` keeps `SFSpeechRecognizer` and a live `AVAudioEngine` tap in the resident process for the length of a recording — the exact RAM shape docs/04 §7.4 says must die with a helper. It's also out of spec in the other direction: docs/09 U3.6 deferred the teleprompter to the backlog and it was built anyway, in the one process with a hard memory budget. Move the following behind the XPC helper, or keep it and document the cost honestly in the PRD.

---

## Sequence and definition of done

**R0 → R1 → R2 → R3.** R0 is non-negotiable and first: the studio is the flagship and it does not currently work. R1 and R2 are the user-visible "fast and light" promise and share the CI-gate work in R2.7 — land the gates *with* the fixes, not after, or the next sprint re-introduces them. R3 is the polish that makes the feature story complete.

**v1.0 ships when:**
- A 10-minute studio recording exports with a moving reconstructed cursor, correctly-timed ripples and captions, smart zooms at the right moments, and a lip-synced camera bubble — after a cut and a speed change.
- Every gate in the R2.7 table is green in CI, including the four new process budgets and the framework denylist.
- `otool -L` on the agent shows no Speech/CoreImage/VideoToolbox/Vision; idle RSS is under 30 MB with the History window open; a 60-second idle sample shows no wakeups from our code except a disclosed, coalesced Sparkle check.
- Scrubbing a 10-minute timeline is under 50 ms per frame and export is ≥ 1.5× realtime and linear in duration.
- Zero public API with tests but no production caller; zero doc comments describing behaviour that doesn't exist.
- CLAUDE.md rule 1 and the CI grep agree with the shipping binary.

**The architectural lesson worth carrying into R4 and beyond:** inside a package this codebase is exemplary; across a process seam it has no types, no tests and no compiler checks — and that is where all four top findings live. C1 is a `TimeInterval` nobody sets; R0.2 is two `TimeInterval`s that mean different things and share a type; R0.5 is an offset nobody records. `InputTelemetry` should carry its time base in the type system the way `Shared.Geometry` carries coordinate spaces. The codebase already knows how to do this — it made the flipped-Y bug class uncompilable in M0. It just never applied the lesson to the time axis.
