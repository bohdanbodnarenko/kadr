# Code Review — M0–M18 Snapshot (2026-08-28)

> Full review of the implemented codebase against CLAUDE.md rules, docs/03 acceptance criteria, and docs/04 architecture. Verdict up front: **the architecture held.** All 10 CLAUDE.md rules pass mechanical checks (zero network ✓, agent linkage ✓, SCK-only ✓, CALayer mouse path ✓, geometry wrappers ✓, signposts ✓); the defects cluster in the newest glue layers — Quick Access actions, recording lifecycle, editor drag logic — not in the foundations. Fix milestones for everything below are defined in `09-uplift-plan.md` Sprint U0.

## CRITICAL — fix before anything else

**C1 · Drag-out from a Quick Access card delivers a dangling URL** — `Kadr/QuickAccess/QuickAccessCardView.swift:80-83` + `QuickAccessManager.swift:360-373`.
With the default `copyToClipboard` action every capture is staged; `.onDrag` finalizes the staged file (moving it) and then builds `NSItemProvider(contentsOf:)` from the view's stale pre-move URL — the drop into Slack/Mail/Finder delivers nothing. This breaks the product's signature interaction under default settings. Root cause is H1 (no file promises). Fix: `NSFilePromiseProvider` drag source that finalizes inside the promise callback.

**C2 · Moving a selected annotation accelerates away from the pointer and floods undo** — `Packages/EditorUI/Sources/EditorUI/EditorDocumentModel.swift:99-119, 176-187`.
`pointerDragged` applies the *absolute* delta from `dragOrigin` to already-translated commands on every event (compounding), and each event pushes a full history snapshot — one drag consumes the 128-entry undo stack (spec: depth ≥ 100 usable). The captured-but-never-read `dragStartRects` is the tell. Fix: preview-position from `dragStartRects` + absolute delta, commit exactly one history entry on `pointerUp`. Add the missing select-mode drag test.

**C3 · A failed stitch bricks recording until relaunch** — `Packages/RecordingCore/Sources/RecordingCore/RecordingEngine.swift:96-118`.
`stop()` sets `.finishing`; if `stitcher.stitch` throws (full disk, unwritable folder) `cleanUp()` and the reset to `.idle` are skipped — every subsequent start throws `alreadyRecording` while the menu looks idle; segments leak in tmp. Fix: `defer` the cleanup/state reset; on error surface the segment directory instead of losing footage.

## HIGH

- **H1 · No `NSFilePromiseProvider` anywhere** (`QuickAccessCardView.swift:77-83`, `HistoryView.swift:116-121`) — docs/03 §2/§6 and docs/04 §5 specify promise drags three times; `NSItemProvider(contentsOf:)` is what enables C1 and breaks staged-file drags generally.
- **H2 · Mic toggle records nothing** (`Settings/RecordingPane.swift:30-32`; `SegmentWriter.swift:78-87` creates the input, but `StreamOutput` never yields mic samples — no `captureMicrophone`, no AVCapture fallback). Silent narration files. Implement per docs/03 §1.8 or disable the toggle honestly.
- **H3 · Desktop hygiene runs *after* the pixels are captured** (`AreaCaptureCoordinator.swift:129-137, 158→192, 373-381`) — icons/wallpaper always end up in the shot, then Finder restarts pointlessly. Reorder + settle-wait.
- **H4 · Full-res PNG/HEIC encode is synchronous on the main actor** (`CaptureOutput.swift:35-53`) — a 5K capture freezes UI for hundreds of ms and blows the 150 ms selection→clipboard budget its own signpost measures. Move export off-main; only the pasteboard write returns.
- **H5 · Card "Delete" leaves a hidden copy in the history library** (`QuickAccessManager.swift:386-395` vs `HistoryStore.ingest` content-addressed copy) — privacy-relevant: sensitive capture "deleted" but retained in App Support until retention expiry. Delete must remove the history record by content hash.
- **H6 · Recording AsyncStream is unbounded** (`RecordingEngine.swift:369`) — IOSurface-backed CMSampleBuffers queue without bound when compositing lags (the scroll path already does `.bufferingNewest(4)` correctly). Use `.bufferingNewest(3)`.

## MEDIUM

- **M1** Card/pin Copy sets file bytes on the pasteboard as `.png` unconditionally — wrong type for JPEG/HEIC/WebP, garbage for video (`QuickAccessManager.swift:293-299, 342-347`). Derive UTType; use URL objects for video.
- **M2** Click halos/keystroke pills desync after pause: overlay source uses wall-clock, engine uses recording time (`RecordingOverlaySource.swift:150-161` vs `RecordingEngine.swift:260-266`). Drive one clock.
- **M3** Pixelate "randomization" is one global grid offset, not per-cell jitter (`RedactionRasterizer.swift:85-99`) — weaker than the docs/03 anti-de-pixelation claim. Per-cell random sampling or fix the claim.
- **M4** Multi-display capture clobbers the clipboard N times; the batch `deliver(_ captures:)` written for exactly this is dead code (`AreaCaptureCoordinator.swift:134-136`).
- **M5** `cancel()` during scroll-stitch races the in-flight stitch → `onFinished` fires for a cancelled capture (`ScrollCaptureCoordinator.swift:278-287`).
- **M6** "Never overwrite" is check-then-act; recordings have no collision counter at all (`CaptureFileWriter.swift:68-77`, `RecordingCoordinator.swift:326-330`). Use `.withoutOverwriting` + retry.
- **M7** Editor closes without an unsaved-changes prompt; `.kadr` write path is dead code until M24 (`EditorWindowController.swift:101-107`).
- **M8** OCR on cards/pins are permanently disabled stubs though the pipeline exists; recording cards lack Trim (`QuickAccessManager.swift:234-247`, `PinPanel.swift:236-238`).
- **M9** PinPanel re-decodes its backing image from disk on every live-resize frame and scroll tick (`PinPanel.swift:103-109`).
- **M10** GIF encoder buffers all frames in RAM until finalize (ImageIO behavior; the "one frame at a time" comment is wrong) — multi-GB peak for long clips (`GIFEncoder.swift:104-115`).
- **M11** `pinFile(at:)` from automation doesn't finalize staged paths → 24 h staging sweep can delete a live pin's file.

## LOW (selected)

Poster JPEG temps never cleaned; thumbnail budget hard-codes `2x`; `MainActor.assumeIsolated` in a `deinit` that can drop off-main (`ContentSharingPickerSession.swift:29-36`); Sparkle check uses a 500 ms poll; `VisionClient` has ~150 duplicated lines; region/scroll captures don't exclude Kadr's own windows (a lingering card can appear in output); dead code: `CaptureOutput.deliver(_ captures:)`, `KadrDocumentFile.write`, `QuickAccessCardActions.share`.

## Compliance scorecard

| CLAUDE.md rule | Verdict |
|---|---|
| 1 Zero network | PASS — Sparkle confined to `Kadr/Updates/`; automation uses CFMessagePort; CI grep is real |
| 2 Process/RAM split | PASS — helper self-terminates (transaction-counted 30 s); editor exits on close |
| 3 SCK only | PASS — no legacy CG capture anywhere; webcam AVCapture is legitimate |
| 4 No SwiftUI in mouse path | PASS — SelectionUI has zero SwiftUI imports; CATransaction-disciplined |
| 5 Concurrency | PASS w/ notes — 4 defensible queues; documented `@unchecked Sendable`; H4/H6/C3 are the exceptions |
| 6 Geometry wrappers | PASS — exemplary; flips centralized |
| 7 Matches docs/03 | PARTIAL — H1, H2, H3, M3, M8 are the deviations |
| 8 Signposts | PASS — every §8 budget path instrumented |
| 9–10 Tests/deps | PASS — 575 package/app tests; only pre-approved deps |

**Best-shape files:** `Shared/Geometry.swift`, `SelectionUI/SelectionOverlayView.swift`, `VisionServices/ScrollStitcher.swift` (mmap + real `phys_footprint` test), `OverlayKit/NonActivatingPanel.swift` + `PerScreenWindowSet.swift`, `HistoryKit/HistoryStore.swift`.
**Worst-shape files:** `QuickAccessManager.swift` (C1/H5/M1/M8), `EditorDocumentModel.swift` (C2), `RecordingEngine.swift` (C3/H6, untested state machine), `AreaCaptureCoordinator.swift` (H3/H4/M4), `RecordingOverlaySource.swift`+`RecordingCoordinator.swift` (M2/H2).
**Coverage gaps that matter:** RecordingCore's engine/writer state machines (where C3 lives) and EditorUI's select-mode drag (where C2 lives) — both get tests as part of their fixes.

The M10 perf harness is real (release build, launch signpost from unified log, `phys_footprint` vs 30/40 MB, idle CPU sample, bundle budget) and honestly documents that capture-latency budgets need a GUI/TCC session CI can't provide.
