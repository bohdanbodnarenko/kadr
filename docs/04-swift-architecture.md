# Swift Architecture — Kadr

> The technical design for a maximally performant, minimum-RAM native macOS capture app, as of 2026 APIs (macOS 14 minimum, macOS 15+ enhancements behind availability checks). Written to be handed to implementers directly.

---

## 1. Architecture at a glance

```
┌────────────────────────────────────────────────────────────────────┐
│  Kadr.app  (LSUIElement agent — the ONLY resident process)         │
│                                                                    │
│  AppKit shell: NSApplicationDelegate + NSStatusItem                │
│  ├─ HotkeyCenter        (KeyboardShortcuts / Carbon, zero-TCC)     │
│  ├─ CaptureEngine  ⟨actor⟩  (ScreenCaptureKit)                     │
│  ├─ OverlayManager      (per-screen NSPanels: selection, HUD)      │
│  ├─ QuickAccessManager  (floating thumbnail panels, drag-out)      │
│  ├─ PinManager          (floating pinned-image panels)             │
│  ├─ RecordingEngine ⟨actor⟩ (SCStream → AVAssetWriter/SCRecording) │
│  ├─ HistoryStore   ⟨actor⟩ (files + SQLite index)                  │
│  └─ Sparkle (lazy)                                                 │
│         idle budget: < 30 MB RSS, 0 timers, 0.0% CPU               │
└───────────────┬───────────────────────────────┬────────────────────┘
                │ NSWorkspace launch + XPC      │ XPC (on demand)
   ┌────────────▼─────────────┐    ┌────────────▼─────────────┐
   │ KadrEditor.app           │    │ HelperTools (XPC service) │
   │ (embedded; .regular      │    │ Vision OCR / subject lift │
   │ activation; dies on      │    │ GIF encode, stitching,    │
   │ close)                   │    │ FTS index (P3)            │
   │ SwiftUI editor UI over   │    │ dies when idle 30 s       │
   │ CALayer canvas           │    └──────────────────────────┘
   └──────────────────────────┘
```

**The three-process split is the RAM strategy.** The agent stays tiny forever; the editor (SwiftUI runtime, undo stacks, full-res bitmaps) and the heavy compute (Vision models — tens of MB on first load — encoders, stitching) live in processes that exit and give every byte back to the OS. This is the single highest-leverage decision in the design.

TCC note: **all ScreenCaptureKit calls stay in the agent process**, so the Screen Recording grant attaches to the app the user sees (XPC permission attribution was buggy in early Sequoia). Helpers only ever receive pixels, never capture them.

---

## 2. Module decomposition (local SPM packages)

Monorepo, one Xcode workspace, app shells are thin; everything else is a local Swift package with enforced dependency direction (lower layers never import higher):

```
Packages/
  CaptureCore/        SCK wrappers: shareable content, screenshots, filters,
                      permission state machine. No UI. Agent-only.
  RecordingCore/      SCStream session, AVAssetWriter pipeline, audio engine,
                      pause/resume segmenting, SCRecordingOutput (15+) path.
  OverlayKit/         AppKit panel primitives: NonActivatingPanel,
                      per-screen window sets, screen-freeze surfaces,
                      collectionBehavior presets. UI but AppKit-only.
  SelectionUI/        The selection overlay: CALayer crosshair/marching-ants,
                      magnifier loupe, dimension badge, keyboard handling.
  AnnotationModel/    Pure value types: AnnotationCommand enum, document model,
                      undo stack, JSON (de)serialization (.kadr). No AppKit.
  AnnotationRender/   Command list → CALayer tree (editing) and → CGContext
                      (export). Blur/pixelate rasterization.
  EditorUI/           SwiftUI editor chrome (toolbars, inspector) hosting the
                      AnnotationRender canvas. Editor app only.
  VisionServices/     OCR, QR, subject mask, redaction-candidate detection.
                      Helper process only; async API over XPC.
  MediaExport/        ImageIO writers (PNG/JPEG/HEIC/WebP), metadata, filename
                      templates, GIF encode orchestration.
  HistoryKit/         Capture records, thumbnail pipeline (ImageIO downsample),
                      SQLite (GRDB) index + FTS5, retention/eviction.
  StudioSession/      Agent-linkable studio models: session packages, input
                      telemetry, clips, the edit document. Foundation/CoreGraphics.
  StudioRender/       Studio frame composer, exporter, cursor reconstruction,
                      transcription. Editor-only (docs/10 R2.1).
  AutomationKit/      URL-scheme + CLI verb parsing → typed AppCommand values.
  SettingsKit/        UserDefaults-backed @Observable settings, migration.
  Shared/             Logging (os.Logger + signposts), geometry helpers
                      (point/pixel, flipped-coords), error types.
```

Rules: packages compile with **Swift 6 language mode, strict concurrency** from day one (Swift 6.2 "Approachable Concurrency": default-MainActor isolation on UI packages, `nonisolated`/`@concurrent` escapes on purpose). Each package unit-testable without the app shell. CI builds packages in parallel.

---

## 3. The agent app shell

### 3.1 AppKit-first, no SwiftUI scene at idle

- `NSApplicationMain` with a plain `AppDelegate`; `LSUIElement = YES`; activation policy `.accessory`.
- **`NSStatusItem`, not `MenuBarExtra`.** We need: programmatic open/close, icon state animation (recording timer), drag-onto-icon, click opens the capture island while right-click opens the menu — all painful or impossible with MenuBarExtra (`.window` style has no proper dismissal/highlight behavior; no status-item access without shims like MenuBarExtraAccess). The menu itself is a plain `NSMenu` (cheapest possible idle path); menu content built lazily in `menuNeedsUpdate`.
- SwiftUI appears **only inside transient windows** via `NSHostingView` (HUD content, settings panes, onboarding) and is torn down (hosting view released, window deallocated) on close. Verified in tests: closing settings returns RSS to baseline.
- Settings window recipe (the known LSUIElement pain): temporarily flip to `.regular` activation policy → activate → show window → revert to `.accessory` on close. Encapsulated once in `OverlayKit.ActivationJuggler`.
- **No timers at idle.** Everything event-driven: hotkeys (Carbon events), `NSApplication.didChangeScreenParametersNotification` for display changes, `NSWorkspace` notifications for wake/login. CI Instruments check: zero wakeups from our code over 60 s idle.

### 3.2 Hotkeys

`KeyboardShortcuts` (sindresorhus, MIT) — Carbon `RegisterEventHotKey` under the hood: sandbox-safe, **no TCC prompts**, user-recordable SwiftUI control for Settings. Known OS bug: Option-only modifiers broken on macOS 15 — the recorder UI disallows those combos. CGEventTap is used **only** for the keystroke-overlay recording feature and only while recording, behind its own Accessibility permission ask.

### 3.3 Launch at login

`SMAppService.mainApp.register()/unregister()`; status re-checked on every launch (user can flip it in System Settings); no third-party lib.

---

## 4. Capture pipeline

### 4.1 Permission state machine (CaptureCore)

States: `unknown → denied → granted → revoked`. Preflight via `CGPreflightScreenCaptureAccess()`; request via `CGRequestScreenCaptureAccess()`; detect grant by polling `CGPreflightScreenCaptureAccess` **only during onboarding** (event-driven elsewhere). Do **not** poll `SCShareableContent` for this: on macOS 15+ that call presents the "screen and audio" TCC sheet, and a one-second loop re-presents it even when the System Settings toggle is already on. First grant requires app relaunch — onboarding automates it (relaunch helper). macOS 15+: expect the ~monthly re-approval nag; detect revocation by SCK error and surface the re-grant sheet. `SCContentSharingPicker` is wired as an alternate no-TCC path for window/display capture (used in the "no permission yet" state so the app is useful immediately).

### 4.2 Still capture

```swift
actor CaptureEngine {
    func freezeAllDisplays() async throws -> [DisplayFreeze]   // < 80 ms goal
    func captureRegion(_ r: CGRect, on d: SCDisplay) async throws -> Capture
    func captureWindow(_ w: SCWindow, opts: WindowOpts) async throws -> Capture
    func captureDisplay(_ d: SCDisplay) async throws -> Capture
}
```

- `SCScreenshotManager.captureImage(contentFilter:configuration:)` everywhere; **never** the deprecated `CGWindowListCreateImage` / `CGDisplayCreateImage` family (legacy CG capture triggers extra TCC alerts on Sonoma+ and is the sanctioned-migration target).
- Region = display filter + `sourceRect` with width/height **multiplied by `backingScaleFactor` per display** (the classic blurry-screenshot bug); colorspace from the display; cursor per settings.
- Freeze path: on hotkey, fire one `captureImage` per display concurrently (`TaskGroup`); results go straight into each overlay panel's `CALayer.contents` as `CGImage` — selection then crops **from the frozen image** (guaranteed WYSIWYG) rather than re-capturing.
- Window capture: `SCContentFilter(desktopIndependentWindow:)` at full backing scale; shadow/transparency via `SCStreamConfiguration` options + compositional background at export.
- The magnifier loupe reads pixels from the already-frozen local image (no per-mousemove capture calls — `SCScreenshotManager` is async and would lag; this sidesteps it entirely).

### 4.3 Recording (RecordingCore)

- macOS 14 path: `SCStream` (`.screen` + `.audio` outputs, `capturesAudio = true`, `excludesCurrentProcessAudio = true`) → `AVAssetWriter` (HEVC hardware, `expectsMediaDataInRealTime`, back-pressure via `isReadyForMoreMediaData`). Drop non-`.complete` frames (`SCStreamFrameInfo.status`); on `.idle` gaps rely on writer timestamps (SCK only delivers on change).
- macOS 15+ path (availability-gated): `SCRecordingOutput` for plain recordings (simpler, encode stays in-framework); mic via `captureMicrophone` + `.microphone` output; keep the AVAssetWriter path for pause/resume segmenting and click-overlay compositing.
- Buffers: IOSurface-backed `CVPixelBuffer`s from SCK's fixed pool; `queueDepth` left at default 3 (each retained frame is a full IOSurface charged partly to WindowServer — never raise without measurement).
- Sample-buffer delivery: SCK's delegate queue is a `nonisolated` fast path that forwards buffers into an `AsyncStream` consumed by the writer actor; `CMSampleBuffer` crosses the boundary via a `@unchecked Sendable` wrapper (documented invariant: single-consumer).
- Pause/resume: finalize segment files, stitch on stop (passthrough remux, no re-encode); crash-safe because segments are always playable.
- Click/keystroke/webcam overlays composited by rendering an overlay layer into the frames before the writer (CALayer render server → per-frame stamp), not post-processing.

### 4.4 Scrolling capture

Assisted tier: low-fps `SCStream` of the selected rect while the user scrolls; frames → HelperTools stitcher (feature-match on overlapping bands via vImage correlation; fallback to template matching); strip tiles stream to disk beyond memory threshold. Auto tier adds synthesized `CGEvent` scroll wheel events with settle detection (frame-diff below epsilon = settled). Accessibility permission requested lazily, only for the auto tier.

---

## 5. Overlay windows (OverlayKit + SelectionUI)

The canonical recipe, applied consistently:

```swift
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // Esc/arrows work w/o app activation
}
// styleMask: [.borderless, .nonactivatingPanel]
// level: .screenSaver (selection) / .floating (thumbnails, pins)
// collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
// isOpaque false, backgroundColor .clear, hasShadow false
// one panel per NSScreen, frame = screen.frame
```

- **Selection overlay content is pure CALayer, not SwiftUI**: the frozen screenshot layer, a dimming layer with even-odd `CAShapeLayer` hole, crosshair lines, the loupe (`CALayer` with magnified sub-image + pixel grid), and a dimension badge (`CATextLayer`). `mouseDragged` mutates shape paths directly — no layout pass, guaranteed 120 Hz on ProMotion.
- SwiftUI (via `NSHostingView`) is used for the *HUD strip* and thumbnail card content where 120 Hz tracking doesn't matter.
- Coordinate discipline lives in `Shared.Geometry`: AppKit bottom-left ↔ CG top-left conversions and point↔pixel scaling are done through typed wrappers (`ScreenPoint`, `PixelRect`) so the flipped-Y bug class can't compile.
- Quick Access cards: file-promise drags (`NSFilePromiseProvider`) so drops into Mail/Slack/Finder materialize the file with its real name even in overlay-only staging mode.
- Pins: `.floating` panels; click-through = `ignoresMouseEvents = true`; backing image is an ImageIO-downsampled texture at panel size × scale, full-res lazily reloaded for zoom/copy.

---

## 6. Annotation editor

- **Separate embedded app** (`Kadr.app/Contents/Applications/KadrEditor.app`), `.regular` activation policy (gets Dock presence + ⌘Tab while open — desirable for a document-style task, and it dodges every LSUIElement focus quirk). Launched via `NSWorkspace.openApplication(at:configuration:)` with the capture handed over by file URL + XPC session for live commands. Exits when its last window closes.
- Document model: `AnnotationModel.Document` = base image ref + `[AnnotationCommand]` (Codable enum: `.arrow(ArrowSpec)`, `.text(TextSpec)`, `.blur(RegionSpec)`, …) + selection state. Undo = command-stack index; `.kadr` = zip(base.png, commands.json).
- Rendering: each command owns a `CAShapeLayer`/`CATextLayer` in an `NSView`-hosted layer tree; hit-testing on model geometry (not layers); live drag mutates one layer's path. SwiftUI drives only toolbar/inspector.
- Export: replay commands into a `CGContext` at native pixel scale (never snapshot the view). Blur/pixelate: rasterize the affected tile through CoreImage **into the base image** so exported files carry no removable overlay; pixelate applies random per-cell jitter.
- Vision work (OCR for smart-highlight/redaction, subject lift) is requested from HelperTools over XPC — the editor process itself never loads Vision models.

---

## 7. Memory & performance engineering (the checklist as rules)

1. **Idle = AppKit + Foundation only.** No SCK/AVFoundation/Vision framework touched until first use (verified: `otool -L` on agent lists them, but no class is messaged pre-capture; init cost paid on first hotkey, which the freeze budget absorbs).
2. **Images:** captures written to disk (staging dir) promptly; agent holds only ImageIO-downsampled thumbnails (`CGImageSourceCreateThumbnailAtIndex`, `kCGImageSourceThumbnailMaxPixelSize`, `shouldCacheImmediately`) — a 5K BGRA capture is ~59 MB decoded, a 400 px card thumb < 1 MB. Full-res never lives in the agent after the overlay action completes.
3. **IOSurface end-to-end** in recording; no `CGImage`/`NSImage` round-trips inside the stream path.
4. **Process exits are the GC.** Editor and helper deaths return Vision models, undo stacks, encoder state. Helper self-terminates after 30 s idle (`NSXPCListener` + transaction counting).
5. **NSCache for thumbnails** with cost limits; responds to memory-pressure DispatchSource by purging.
6. **Signposts everywhere** (`os_signpost`): hotkey→overlay, selection→clipboard, launch→ready. CI runs a release-build perf test on Apple Silicon comparing against the budget table in the PRD (§8) and fails the build on regression.
7. **Startup:** no storyboard/xib; status item + hotkey registration only; everything else lazy. Target < 300 ms to ready.

---

## 8. Concurrency model

- Swift 6.2, strict concurrency, Approachable-Concurrency flags (`-default-isolation MainActor` on UI packages, `NonisolatedNonsendingByDefault`, `InferSendableFromCaptures`).
- `@MainActor`: all AppKit/window/menu code. Actors: `CaptureEngine`, `RecordingEngine`, `HistoryStore`. `@concurrent` only on provably parallel pure work (stitch correlation, thumbnail generation).
- Boundary rules: SCK delegate callbacks are `nonisolated` → `AsyncStream`; `CMSampleBuffer`/`IOSurface` cross via documented `@unchecked Sendable` wrappers; no `DispatchQueue` usage outside SCK-required handler queues.
- Cancellation: every capture flow is a `Task` tree hung off the initiating command; Esc cancels the tree; engines are cancellation-safe (streams stopped, writers finalized).

## 9. State, settings, persistence

- **No TCA.** Plain `@Observable` models + actor services + environment injection. Rationale: the app's complexity is in AppKit window management and media pipelines — reducer indirection buys testability we already get from package-level unit tests, at real dependency and cognitive cost. (Capso, Mio, Snapzy all converge on this.)
- Settings: `SettingsKit` `@Observable` façade over `UserDefaults` with typed keys + migration versions; hotkeys stored by `KeyboardShortcuts`.
- History: content-addressed files under `~/Library/Application Support/Kadr/Captures/` + GRDB/SQLite index (records, thumbnails path, OCR text FTS5 (P3)); retention/eviction in `HistoryKit`; the DB is disposable (rebuildable from files + sidecar JSON).

## 10. Distribution & updates

- **Developer ID + Hardened Runtime + notarization** (mandatory in practice: Sequoia removed the Control-click Gatekeeper bypass; unsigned OSS apps are a support-ticket factory — Flameshot's top macOS complaint). Funded by sponsors ($99/yr).
- **Sparkle 2**: EdDSA-signed appcast on GitHub Releases/Pages; delta updates; `generate_appcast` in CI. Update checks opt-in-by-default-on with clear setting (the agent's only background network touch).
- Artifacts: notarized DMG + Homebrew cask (`brew install --cask kadr`); `--version`-stamped reproducible-ish builds (stretch).
- **No sandbox** (auto-scroll needs synthesized events; save-anywhere UX; SMAppService helpers) — a future reduced MAS variant is possible since SCK + Carbon hotkeys are sandbox-compatible, but not a goal.
- Entitlements: none beyond Hardened Runtime defaults; usage strings for the microphone (recording), camera (webcam overlay) and on-device speech recognition (teleprompter follow / studio tidy); no persistent-content-capture (Apple won't grant it to a screenshot utility; design assumes the monthly re-approval exists). The editor additionally declares `CFBundleDocumentTypes` for images, movies, `.kadr` projects, `.kadrrec` sessions and `.kadrpreset` looks (docs/09 U1.8, docs/10 R3.5).

## 11. Testing & CI

- Unit: AnnotationModel (command algebra, undo), Geometry (coordinate conversions — table-driven), filename templates, stitcher (golden fixtures of app scroll captures), settings migration.
- Integration (macOS runner): capture-against-known-window pixel assertions; overlay lifecycle leak tests (`XCTMemoryMetric`); permission-state machine with TCC pre-seeded VMs.
- Perf: signpost-driven budget suite (PRD §8) on M-series runner, release config, results posted to a public dashboard — the "performance credential" is a published artifact.
- Static: SwiftLint/SwiftFormat; layering check (script asserts **no networking imports anywhere except Sparkle** — `import Network`/`URLSession` symbols outside the update path fail CI, making the "zero network, drag-and-drop only" promise machine-verified); `strict-concurrency` warnings-as-errors.

## 12. Decision log (summary)

| Decision | Choice | Rejected | Why |
|---|---|---|---|
| Min macOS | 14 | 12.3, 13 | SCScreenshotManager/Picker/@Observable; no dual paths |
| Shell | AppKit + NSStatusItem | SwiftUI MenuBarExtra | control, idle cost, known Extra limitations |
| Selection overlay | CALayer in NSPanel | SwiftUI Canvas | 120 Hz mouse path, no layout pass |
| Editor location | separate embedded app | in-process window | RAM isolation, activation policy, crash isolation |
| Vision/encoders | XPC helper, self-terminating | in agent | model RSS dies with process |
| Hotkeys | KeyboardShortcuts (Carbon) | CGEventTap | no TCC, sandbox-safe, standard |
| Capture API | ScreenCaptureKit only | legacy CG | deprecation + extra TCC alerts on legacy path |
| State | @Observable + actors | TCA | complexity lives in AppKit/media, not state graphs |
| Storage | files + GRDB/SQLite | Core Data | disposable index, FTS5, no schema lock-in |
| Updates | Sparkle 2 + DMG + Homebrew | MAS | sandbox limits, Sparkle ban, license model |
| License | MIT | GPL | adoption; GPL neighbors remain read-only references |
| Language mode | Swift 6.2 strict | Swift 5 mode | new codebase; approachable-concurrency defaults |

## 13. Reference implementations consulted

Snapzy (BSD-3 — broad CleanShot-clone donor) · Apple CaptureSample (SCK canon) · Mio (actor pipeline, <80 ms freeze, vector commands) · TRex (MIT, OCR + automation) · Pika (MIT, eyedropper) · ScrollSnap (scrolling capture) · QuickRecorder (AGPL, read-only: system-audio + recording patterns) · Capso (BUSL, read-only: 12-package SPM layout, Swift 6) · sindresorhus/KeyboardShortcuts · Sparkle 2 docs · steipete's LSUIElement-settings write-up · multi.app NSStatusItem write-up · Nonstrict SCK/AVAssetWriter series.
