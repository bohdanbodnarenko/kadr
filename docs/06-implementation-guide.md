# Implementation Guide — Step-by-Step Milestones & AI Prompts

> How to actually build Kadr from the doc set, milestone by milestone.
> Each milestone has: **Goal → Doc refs → Paste-ready prompt → Done when** (acceptance checks you run yourself).
> The prompts are written for an AI coding agent (Claude Code or similar) working inside the repo, but they double as a human task list.

---

## 0. How to work through this guide

**Setup that makes the prompts work well:**

1. Create the repo and copy this whole doc set into `docs/` — the prompts reference doc sections by number, and the agent should always be able to read them.
2. Add the `CLAUDE.md` from Appendix A at the repo root. It encodes the non-negotiable rules (layering, perf budgets, zero-network) so every session inherits them without re-pasting.
3. **One milestone per session/branch.** Each prompt is scoped to be completable and verifiable in one sitting. Merge only when the "Done when" list passes.
4. Order matters within a phase (each milestone builds on the previous), but M-numbers across phases can interleave once P1 ships.
5. After every milestone: run the app, run tests, and check Activity Monitor RSS yourself. The budgets in PRD §8 are the definition of done, not decoration.
6. When a prompt says "per doc 04 §X", the agent should open and follow that section literally — the docs are the spec; the prompt is just the work order.

**Prerequisites (human tasks, no prompts):**

- Xcode 16+ on macOS 15/26; an Apple Developer account ($99/yr) if you want signing/notarization from M11 (everything before that runs locally unsigned).
- Name is decided: **Kadr** (bundle ID `app.kadr.Kadr`, CLI `kadr`, scheme `kadr://`). Register the GitHub org/repo `kadr` and a domain (kadr.app / getkadr.app) before the first public release.
- `brew install swiftlint swiftformat create-dmg` (create-dmg needed at M11).

---

## Phase 0 — Foundations

### M0.1 — Repo scaffold, packages, CI

**Goal:** the monorepo skeleton with all SPM packages compiling empty, lint/format, and the layering CI check.
**Docs:** 04 §2 (module list + rules), 04 §11 (static checks), PRD §8 (budgets, for CI stubs).

```text
Read docs/04-swift-architecture.md §2 and §11, and CLAUDE.md.

Create the project skeleton:
1. An Xcode workspace with one app target `Kadr` (macOS 14.0 deployment,
   Swift 6 language mode, strict concurrency) — for now a plain AppKit app with
   an empty AppDelegate, LSUIElement=YES in Info.plist.
2. Local SPM packages under Packages/ exactly as listed in doc 04 §2 (skip
   none): CaptureCore, RecordingCore, OverlayKit, SelectionUI, AnnotationModel,
   AnnotationRender, EditorUI, VisionServices, MediaExport, HistoryKit,
   AutomationKit, SettingsKit, Shared. Each: one placeholder type, one passing
   unit test, Swift 6 strict concurrency enabled. Wire the dependency
   direction from doc 04 §2 into Package.swift files (lower layers never
   import higher ones).
3. SwiftLint + SwiftFormat configs (sensible defaults, 120 cols).
4. Scripts/check-layering.sh: fails if (a) any package other than the Sparkle
   integration imports Network or uses URLSession symbols, (b) EditorUI or
   VisionServices are linked into the agent app target. Add Scripts/check-size.sh
   stub (app bundle < 15 MB, per PRD §8).
5. GitHub Actions workflow: build workspace, run all package tests, run
   swiftlint, run both scripts, on macos-15 runner.
Do not implement any features. Everything must build clean with zero warnings.
```

**Done when:** `xcodebuild` succeeds; all package tests pass; CI green; running the app shows nothing (no Dock icon, no window) and idles at ~10–15 MB in Activity Monitor.

### M0.2 — Agent shell: status item, menu, hotkeys, login item, settings shell

**Goal:** the resident agent skeleton — everything a user touches before any capture exists.
**Docs:** 04 §3 (entire), 03 §8.1, §8.3; PRD §8 (idle budgets).

```text
Read docs/04-swift-architecture.md §3 and docs/03-features.md §8.1/§8.3.

In the Kadr app target + SettingsKit + OverlayKit:
1. NSStatusItem with a template icon; NSMenu built lazily in menuNeedsUpdate
   with placeholder items for: Capture Area, Capture Window, Capture Screen,
   OCR (all disabled for now), separator, Settings…, Check for Updates
   (disabled), Quit. Menu items show hotkey hints.
2. HotkeyCenter using the sindresorhus/KeyboardShortcuts SPM package: define
   commands (captureArea, captureWindow, captureFullscreen, captureText,
   capturePreviousArea) with defaults; fire logs for now. Disallow
   Option-only modifier combos in the recorder (macOS 15 bug, doc 04 §3.2).
3. SettingsKit: @Observable AppSettings over UserDefaults with typed keys +
   migration version, covering doc 03 §8.3 General pane fields.
4. Settings window: SwiftUI panes (General, Shortcuts with
   KeyboardShortcuts.Recorder) hosted in an NSHostingView window, using the
   ActivationJuggler pattern from doc 04 §3.1 (flip .accessory→.regular→back)
   so it reliably becomes key from an LSUIElement app. Window and hosting
   view must be fully deallocated on close — add a debug assertion.
5. Launch at login via SMAppService.mainApp with status re-check on launch
   (doc 04 §3.3), toggle in General settings.
Rules: no timers, no SwiftUI scenes at idle, no framework touched beyond
AppKit/Foundation until a window opens. Add signposts: launch→statusItemReady.
```

**Done when:** hotkeys log from any app with no permission prompts; settings opens/closes and RSS returns to baseline; login-item toggle survives System Settings inspection; idle CPU 0.0%, zero wakeups in a 60 s Instruments sample; cold launch signpost < 300 ms.

---

## Phase 1 — MVP

### M1 — CaptureCore: permissions + still capture engine

**Goal:** the whole ScreenCaptureKit layer, headless (no UI yet) — testable from a debug menu.
**Docs:** 04 §4.1–4.2; 03 §1.1–1.3 (what the engine must support).

```text
Read docs/04-swift-architecture.md §4.1–4.2 and docs/03-features.md §1.1–1.3.

Implement in Packages/CaptureCore (agent-only, no UI):
1. PermissionCoordinator: the unknown→denied→granted→revoked state machine
   from doc 04 §4.1. CGPreflightScreenCaptureAccess/CGRequestScreenCaptureAccess,
   grant detection by SCShareableContent probe (polled ONLY while onboarding
   is visible), relaunch helper for the first grant, revocation detection via
   SCK error mapping. Also expose an SCContentSharingPicker path that works
   with zero TCC permission.
2. actor CaptureEngine with the API from doc 04 §4.2: freezeAllDisplays()
   (concurrent TaskGroup, one SCScreenshotManager.captureImage per display,
   signposted, <80 ms target), captureRegion (display filter + sourceRect,
   width/height × backingScaleFactor — write the point/pixel conversions via
   typed wrappers in Shared.Geometry: ScreenPoint, PixelRect, per-display
   scale; unit-test the conversions table-driven including flipped-Y),
   captureWindow (SCContentFilter(desktopIndependentWindow:), shadow +
   transparent-background options), captureDisplay.
3. Capture result type: CGImage + metadata (display, scale, colorspace, rect,
   frontmost app name/bundle id).
4. Never call CGWindowListCreateImage/CGDisplayCreateImage anywhere.
5. Debug-only menu items in the agent to exercise each call and write PNGs
   to ~/Desktop for manual verification.
Unit tests for geometry; an integration test target (skipped on CI without
TCC) that captures a known-color test window and asserts pixels.
```

**Done when:** debug captures are pixel-correct on a mixed-DPI two-display setup (compare against ⇧⌘4 output); window capture is unoccluded with correct alpha in transparent mode; freeze of 2 displays < 80 ms signposted on M-series.

### M2 — Selection overlay (freeze-frame area capture)

**Goal:** the signature interaction: hotkey → frozen screen → crosshair selection with loupe → captured region.
**Docs:** 04 §5 (recipes), 03 §1.1 (full behavior spec + edge cases).

```text
Read docs/04-swift-architecture.md §5 and docs/03-features.md §1.1 fully —
§1.1 is the behavioral spec, implement all of it.

In OverlayKit + SelectionUI:
1. OverlayKit primitives: NonActivatingPanel (NSPanel subclass,
   canBecomeKey=true), styleMask [.borderless, .nonactivatingPanel], level
   .screenSaver, collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary,
   .stationary], clear/nonopaque/no-shadow config helper; PerScreenWindowSet
   managing one panel per NSScreen incl. hot-plug via
   didChangeScreenParametersNotification.
2. SelectionUI: pure CALayer content view (no SwiftUI in the mouse path):
   frozen screenshot layer, dimming layer with even-odd CAShapeLayer hole,
   crosshair lines, 8× magnifier loupe (magnified sub-image from the FROZEN
   image + pixel grid + color/coords readout), CATextLayer dimension badge
   (points and pixels). mouseDragged mutates layer paths directly.
3. Interactions from doc 03 §1.1: Space to move selection, arrows nudge 1px
   (shift=10), numeric W×H entry, option-drag from center, shift aspect lock,
   Esc cancels, NSCursor.crosshair. Selections are per-display (cannot span).
4. Flow wiring: captureArea hotkey → CaptureEngine.freezeAllDisplays →
   panels show frozen images → selection commit → crop from the frozen image
   (NOT a re-capture) → hand off to a stub CaptureOutput (copies PNG to
   clipboard for now). capturePreviousArea replays the stored last rect
   instantly with no UI.
5. Signposts: hotkey→overlayVisible (<100 ms budget), commit→clipboard
   (<150 ms for a 5K region).
On Esc or commit, all panels and layers must be deallocated — assert in debug.
```

**Done when:** the full accept list in doc 03 §1.1 passes; tracking feels 120 Hz-smooth on ProMotion; RSS returns to baseline after capture; screenshots match frozen state even with a video playing under the overlay.

### M3 — Window & fullscreen capture UI, self-timer

**Docs:** 03 §1.2, §1.3, §1.5.

```text
Read docs/03-features.md §1.2, §1.3, §1.5.

1. Window-pick mode on the frozen overlay: hover highlight (tint + outline +
   title chip) using SCShareableContent window geometry mapped into the
   frozen image; click captures via CaptureEngine.captureWindow honoring
   shadow/transparent settings; Tab cycles same-app windows; ⌥ at click
   flips the shadow setting.
2. Fullscreen/display hotkey: silent instant capture of all displays (file
   per display; setting for stitched), no overlay.
3. Self-timer: 3/5/10/custom seconds; floating countdown badge panel
   (top-right, non-interactive, excluded from capture via
   SCContentFilter excludingWindows); Esc cancels; works with area
   (remembered region), window, fullscreen.
Wire all of these to hotkeys + the status menu, replacing M0.2 placeholders.
```

**Done when:** doc 03 accepts for §1.2 pass (occluded window unoccluded, real alpha); timer badge never appears in output; menu/hotkey parity.

### M4 — MediaExport + capture output policy

**Docs:** 03 §9 (files), 03 §2 (default actions), 02 §5 P1 list.

```text
Read docs/03-features.md §9 (Files bullet) and the default-action behavior in §2.

Implement Packages/MediaExport:
1. ImageIO writers: PNG (default), JPEG(q), HEIC, WebP; embed color profile;
   144-dpi metadata tag for Retina; optional 2x→1x downscale path
   (high-quality CGContext resample).
2. Filename template engine: {app}/{date}/{time}/{w}x{h}/{counter} tokens,
   unit-tested; atomic writes; never-overwrite auto-increment.
3. CaptureOutput policy engine replacing the M2 stub: per settings —
   clipboard / save to folder / both / overlay-only staging (file written to
   the staging dir under Application Support, finalized to the save folder on
   first user action). Staging dir cleaned per retention rules on launch.
4. Full-res images must not be retained in the agent after export: verify
   with a debug memory assertion (doc 04 §7 rule 2).
```

**Done when:** every format opens correctly in Preview with right DPI/profile; template engine tests pass; a 5K capture leaves agent RSS within 5 MB of baseline after export.

### M5 — Quick Access Overlay

**Goal:** the product's signature surface.
**Docs:** 03 §2 (entire — treat as the spec), 04 §5 (panel recipes, file promises).

```text
Read docs/03-features.md §2 fully and implement all of it.

In OverlayKit + a new QuickAccess module folder in the app target:
1. Thumbnail card panels: .floating level non-activating panels in the
   configured corner of the capture's display; slide-in respecting
   reduced-motion; stack up to 5 with older cards collapsing behind;
   never overlapping the Dock.
2. Card content in SwiftUI via NSHostingView (thumbnail from ImageIO
   downsample ≤400px, filename, dimensions on hover).
3. Interactions: drag-out as NSFilePromiseProvider (file materializes with
   its real templated name even in overlay-only staging mode — receiving in
   Finder/Slack/Mail must work); single-click expands action row
   Copy · Save · Annotate (stub) · Pin (stub) · OCR (stub) · Share sheet
   (NSSharingServicePicker) · Delete; double-click = Annotate; ⌫ deletes;
   swipe/two-finger dismiss.
4. Auto-dismiss timer per settings (default off); dismiss ≠ delete;
   "Restore recently closed" menu command + hotkey brings back last N.
5. Overlay settings pane (corner, size, timeout, stacking) per doc 03 §8.3.
The card must never steal key focus; VoiceOver must reach every action.
```

**Done when:** doc 03 §2 accept list passes; drag into Slack/Mail/Finder/Chrome all deliver correctly named files; focus never leaves the frontmost app.

### M6 — Pinned screenshots

**Docs:** 03 §4 (spec + accepts), 04 §5 (pins paragraph).

```text
Read docs/03-features.md §4 and implement all of it: floating .canJoinAllSpaces
panels from any capture source; corner-drag scaling, ⌥-scroll zoom + opacity,
double-click 100%, click-through mode (⌘⌥L, ignoresMouseEvents) with a
visible affordance to exit, arrow-key nudge, right-click menu (copy, save,
annotate stub, OCR stub, close), Close All Pins command. Backing image =
downsampled texture at panel size × scale; full-res lazily reloaded only for
zoom>1 or copy (doc 03 §4 accept: 20 pins ≤ 40 MB added RSS — write a debug
measurement harness for this).
```

**Done when:** doc 03 §4 accepts pass, including the 20-pin RSS harness.

### M7a — Annotation model (pure Swift, TDD this one)

**Docs:** 04 §6 (document model), 03 §3 (tool semantics).

```text
Read docs/04-swift-architecture.md §6 and docs/03-features.md §3.

Implement Packages/AnnotationModel with NO AppKit imports:
1. AnnotationCommand: Codable enum covering P1 tools — arrow (straight/
   curved, 3 head styles), shape (rect/roundedRect/ellipse/line, fill/stroke),
   freehand (smoothed path points), highlighter, text (spec incl. style
   presets), blurRegion(style: blur|pixelate), counterBadge(number),
   crop(rect, canExpandCanvas). Each with geometry + style structs.
2. Document: immutable base-image reference (size/scale), ordered command
   stack, selection set, undo/redo as stack-index history (≥100 depth),
   z-order ops, hit-test geometry pure functions (no rendering).
3. Counter renumbering on reorder; style memory ("last used per tool").
4. .kadr serialization: zip(base.png, commands.json) round-trip.
Exhaustive unit tests: command codability round-trips, undo/redo laws,
hit-testing tables, renumbering, .kadr round-trip. 100% of this package's
public API covered.
```

**Done when:** package tests green with real coverage; no UI framework in the dependency tree.

### M7b — Editor app + rendering canvas

**Docs:** 04 §6 (process split, rendering, export), 03 §3 (tools UX + accepts).

```text
Read docs/04-swift-architecture.md §6 and docs/03-features.md §3.

1. Create the embedded editor app target KadrEditor.app (placed in
   Kadr.app/Contents/Applications/), activation policy .regular,
   launched from the agent via NSWorkspace.openApplication with the capture
   handed over by file URL + an NSXPCConnection for live commands; exits
   fully when its last window closes.
2. AnnotationRender: (a) editing path — each command owns a CAShapeLayer/
   CATextLayer in an NSView layer tree; selection handles as layers;
   hit-testing against MODEL geometry; live drag mutates exactly one layer's
   path; (b) export path — replay commands into CGContext at native pixel
   scale. Blur/pixelate rasterize INTO the base image tile via CoreImage at
   export (pixelate with per-cell random jitter) so exports carry no
   removable overlay.
3. EditorUI: SwiftUI toolbar (tool picker with keyboard shortcuts),
   inspector (color/width/style per tool, last-used memory), zoom/pan
   (pinch + ⌘0/⌘=), title-bar proxy icon drag-out, ⌘C flattened copy,
   ⌘S save via MediaExport, "Copy without annotations".
4. Wire the overlay/pin "Annotate" actions to open the editor.
Implement every P1 tool from doc 03 §3 with its listed micro-behaviors
(arrow curve mid-handle, counter auto-increment + drag-reorder renumbering,
text inline editing with 5 presets, crop with aspect presets + canvas
expand, marquee + ⌘-click multiselect, arrow-key nudge).
```

**Done when:** doc 03 §3 accepts pass: 60 fps drags on a 5K capture (Instruments), undo ≥100, exported blur unrecoverable (verify pixel entropy), agent RSS unchanged while editor is open, editor process gone from `ps` after close.

### M8 — VisionServices helper + OCR capture mode

**Docs:** 04 §1 (helper), 03 §1.7 (spec + accepts).

```text
Read docs/04-swift-architecture.md §1 (HelperTools) and docs/03-features.md §1.7.

1. Create the HelperTools XPC service target: NSXPCListener, transaction-
   counted, self-terminates after 30 s idle. All ScreenCaptureKit stays in
   the agent — the helper only ever receives image data.
2. Packages/VisionServices (linked ONLY in the helper): async OCR (macOS 14
   VNRecognizeTextRequest with .accurate + automatic language detection;
   RecognizeTextRequest on 15+ behind availability), QR/barcode decode,
   protocol-based XPC API with Codable results (text, boxes, confidence).
3. Capture Text mode: the M2 selection overlay re-skinned (distinct tint +
   TEXT badge) → crop → helper OCR → clipboard, with line-break setting
   (preserve/collapse) → toast panel showing preview + char count; QR
   payloads offer Open/Copy. Wire hotkey + menu + overlay-card and pin OCR
   actions.
Measure and log helper spawn+model+recognize time; target <1 s typical
region on M-series.
```

**Done when:** doc 03 §1.7 accepts pass; helper disappears from `ps` 30 s after use; agent RSS unaffected by OCR use.

### M9 — Onboarding + permission UX

**Docs:** 03 §8.2 (spec), 04 §4.1 (state machine hooks).

```text
Read docs/03-features.md §8.2 and implement the 3-screen onboarding exactly:
what-it-does + hotkey cheatsheet; Screen Recording TCC screen (honest
macOS 15 monthly-reprompt explanation, deep-link to System Settings pane,
live grant detection via the M1 PermissionCoordinator probe-while-visible,
automated relaunch after first grant); defaults choice (clipboard-first vs
file-first, save folder, launch-at-login opt-in). Every screen skippable,
<2 min total, reduced-motion respected. Also: the revoked-permission
recovery sheet (doc 03 §9 Interruptions) shown when SCK errors indicate
revocation mid-use, and the SCContentSharingPicker no-permission fallback
path offered when the user declines TCC.
```

**Done when:** fresh-VM first-run reaches a successful capture in <2 min without touching docs; revoking permission mid-session shows recovery, never crashes.

### M10 — Perf harness (make the budgets real)

**Docs:** PRD §8 (the table), 04 §7 + §11.

```text
Read docs/02-prd.md §8 and docs/04-swift-architecture.md §7/§11.

Build the perf suite that CI runs on release builds:
1. Signpost-driven tests for: cold launch→ready, hotkey→overlayVisible,
   commit→clipboard (5K region), asserting the PRD §8 budgets with headroom
   thresholds (warn at 80%, fail at 100%).
2. RSS assertions via task_info: idle after launch (<30 MB warn/40 fail);
   after 10 capture+dismiss cycles and editor open/close, back under 60 MB
   within 30 s.
3. Idle-wakeups test: 60 s sample asserting zero timers/wakeups from our
   code.
4. Bundle-size check wired into check-size.sh (<15 MB).
5. A perf-results.json artifact uploaded from CI + a README badge script.
Then profile the current app against all budgets and fix what fails —
typical suspects per doc 04 §7: eager framework init, retained CGImages,
non-lazy NSHostingViews, forgotten observers.
```

**Done when:** all budgets green on CI two runs in a row; numbers published in README.

### M11 — Distribution: signing, notarization, Sparkle, DMG, Homebrew

**Docs:** 04 §10; PRD §9.

```text
Read docs/04-swift-architecture.md §10.

1. Release pipeline (GitHub Actions): archive with Developer ID signing +
   Hardened Runtime for the agent, editor, and helper (correct nested
   signing order), notarytool submit + staple, create-dmg, upload to a
   GitHub Release. Secrets via repo settings; document them in
   docs/RELEASING.md.
2. Sparkle 2 via SPM: EdDSA keys (document generation + storage),
   generate_appcast in CI publishing appcast.xml to GitHub Pages; delta
   updates on; "Check for Updates" menu item + Settings toggle for
   automatic checks. Sparkle is the ONLY networking allowed — confirm
   check-layering.sh still passes.
3. Homebrew cask formula in a tap repo + install docs.
4. NSMicrophoneUsageDescription placeholder (P2), no other entitlements
   beyond Hardened Runtime defaults.
```

**Done when:** a tagged commit produces a notarized DMG that installs and launches clean on a fresh Mac with no Gatekeeper friction; Sparkle updates from vN to vN+1 in a test.

> **🎉 P1 ships here.** Cut v0.1, post to HN/Product Hunt, open good-first-issues.

---

## Phase 2 — parity

### M12 — RecordingCore: MP4 with system audio

**Docs:** 04 §4.3 (pipeline), 03 §1.8 (spec).

```text
Read docs/04-swift-architecture.md §4.3 and docs/03-features.md §1.8.

Implement Packages/RecordingCore + recording UI:
1. actor RecordingEngine: SCStream (.screen + .audio, capturesAudio=true,
   excludesCurrentProcessAudio) → AVAssetWriter (HEVC hardware default,
   H.264 option; expectsMediaDataInRealTime; back-pressure). nonisolated
   sample-handler fast path → AsyncStream → writer actor, CMSampleBuffer in
   a documented @unchecked Sendable wrapper. Drop non-.complete frames;
   handle .idle via writer timestamps. queueDepth stays at default 3.
2. Availability-gated macOS 15 path: SCRecordingOutput for plain recordings;
   captureMicrophone for mic (AVCaptureSession fallback on 14, separate
   track).
3. Pause/resume by segment files + passthrough remux on stop (gapless,
   crash-safe: every segment independently playable).
4. UI per doc 03 §1.8: same selection grammar → pre-record control strip
   (mic picker/toggle, system-audio toggle, countdown) → status-item red
   timer (click stop; menu pause/cancel) + optional floating stop button →
   overlay card with Trim/Save/Copy/GIF(stub)/Delete.
5. Trim editor in the editor app (AVPlayer + trim handles, passthrough
   export). Auto-DND during recording; cursor toggle.
```

**Done when:** doc 03 §1.8 accepts: 1080p60 HEVC <15% CPU on M1; A/V drift <1 frame over 10 min; kill -9 mid-recording leaves a playable file.

### M13 — GIF export

```text
Add GIF export to the recording flow per docs/03-features.md §1.8: trim
first, then encode ≤50 fps palette-optimized. Evaluate: gifski via bundled
CLI subprocess (AGPL isolation — document the licensing rationale in the
repo, per PRD §11 open question 2) vs a pure-Swift encoder; benchmark
quality/size on 3 reference recordings and implement the winner behind a
GIFEncoding protocol in MediaExport, with a size estimate shown pre-export.
Run in HelperTools, never the agent.
```

**Done when:** a 10 s 1080p clip exports visibly-good GIF < 12 MB; agent RSS flat during encode.

### M14 — Recording extras: click viz, keystroke overlay, webcam PiP

**Docs:** 03 §1.8 details; 04 §4.3 (overlay compositing).

```text
Per docs/03-features.md §1.8 and 04 §4.3 compositing note:
1. Click visualization: global mouse-down monitor while recording only;
   pulse circles composited into frames pre-writer (color/size/style
   settings).
2. Keystroke overlay: CGEventTap active ONLY while recording and only after
   its own Accessibility permission ask (doc 04 §3.2); ⌘-combos-only or
   all-keys modes, position/size/theme settings, rendered into frames.
3. Webcam PiP: AVFoundation capture into a movable/resizable circle or
   rounded-rect layer composited into the recording; device picker.
Each feature individually toggleable; none may exist as running code while
not recording.
```

**Done when:** overlays appear in output not on screen-only; taps/monitors provably torn down after stop (`sample` shows none); permission asked lazily.

### M15 — Scrolling capture

**Docs:** 03 §1.6 (two tiers + accepts), 04 §4.4.

```text
Read docs/03-features.md §1.6 and docs/04-swift-architecture.md §4.4.

1. Assisted tier: region select → low-fps SCStream while the USER scrolls →
   frames to HelperTools stitcher: vImage correlation on overlapping bands,
   template-match fallback, tiles streamed to disk beyond ~16k px tall;
   live growing-strip preview; Stop → stitched image to the editor's
   scrolled-canvas mode. Low-confidence seams flagged with
   keep/retry/export-frames choices.
2. Auto tier: synthesized CGEvent scroll-wheel events with frame-diff settle
   detection; Accessibility permission requested lazily with explainer.
3. Test fixtures: recorded frame sequences from Safari long page, VS Code,
   Slack thread, Finder list, Terminal scrollback; stitcher unit tests
   against golden outputs for all five.
```

**Done when:** the five golden cases stitch seamlessly; memory bounded (verify with a 30k-px page); assisted tier works with zero new permissions.

### M16 — History

**Docs:** 03 §5; 04 §9 (storage).

```text
Read docs/03-features.md §5 and docs/04-swift-architecture.md §9.

Packages/HistoryKit: GRDB/SQLite index over content-addressed files in
Application Support (records: file ref, type, dims, app, timestamps;
thumbnails via ImageIO downsample; DB rebuildable from files + sidecar
JSON). Retention setting (forever/30d/7d/session) + size cap with LRU
eviction. UI: last-8 thumbnail strip in the status menu; History window
(grid, type/date filters, drag-out, batch select, reveal, delete-with-file,
storage meter). Wire "Restore recently closed" to history. Cold-open
<400 ms at 1k items (paged thumbnails) — add a seeded perf test.
```

**Done when:** doc 03 §5 accepts pass incl. the 1k-item perf test; eviction verified.

### M17 — Beautify backgrounds + desktop hygiene

**Docs:** 03 §3 P2 additions, 03 §7.

```text
1. Editor beautify panel per docs/03-features.md §3 P2: padding, solid/
   gradient/image backdrop, corner radius, shadow, aspect presets,
   auto-balance (content centered with equalized margins), savable presets.
   Implemented as AnnotationModel commands (stays non-destructive/undoable).
2. Desktop hygiene per §7: hide desktop icons + widgets toggle (menu/HUD/
   hotkey), auto-hide while recording setting, temporary wallpaper override
   during capture; standalone screen-freeze command; crosshair precision
   mode toggle in the selection overlay.
```

**Done when:** social-preset exports look CleanShot-grade on 3 sample shots; icons hide/restore reliably incl. after crash (state re-asserted on launch).

### M18 — Auto-redaction assist

**Docs:** 03 §3 P3 list (pulled forward per PRD P2), 01 §7 gap 6.

```text
In VisionServices + EditorUI per docs/03-features.md §3: run OCR over the
capture in HelperTools, then pattern-match candidates: emails, phone
numbers, credit-card shapes (Luhn), IBAN, JWT/API-key entropy heuristics
(document each regex with tests). Editor shows dashed highlights over
candidates with a review strip (accept one/all → blur commands appended);
never auto-applies. Also "Redact all text matching…" find field.
All local, helper-only, lazy.
```

**Done when:** seeded test images (10 secrets across formats) → 0 missed at review stage, no auto-apply; pattern tests green.

### M19 — Automation: URL scheme, CLI, Shortcuts

**Docs:** 03 §8.4; 04 §2 (AutomationKit).

```text
Read docs/03-features.md §8.4. Packages/AutomationKit: typed AppCommand
enum + parser shared by three frontends: (1) URL scheme
kadr://… with the verbs and params from §8.4 plus a CleanShot-verb
alias table; (2) a CLI binary (installed via Settings→Advanced symlink)
speaking the same verbs, --json output, nonzero exit on cancel — it
forwards to the agent over the URL scheme/XPC, it does NOT capture itself;
(3) App Intents (Shortcuts actions) wrapping the same commands. Parser
unit-tested exhaustively; document every verb in docs/AUTOMATION.md.
```

**Done when:** Raycast script using CleanShot-style verbs works via aliases; `kadr capture-area --json` returns the file path; Shortcuts app shows the actions.

---

## Phase 3 — beyond parity (prompts in brief)

Run these the same way — read the doc section, implement, verify accepts:

- **M20 OCR-searchable history** (03 §5 P3): FTS5 index built in HelperTools on idle+power only, opt-out setting; search field in History window; "zero agent idle cost" verified by the M10 harness.
- **M21 Pixel ruler + measurements** (03 §3 P3, 01 §7 gap 7): overlay + editor measure tool, px/pt readouts, edge-snap to detected rects.
- **M22 Color picker** (03 §3 P3): loupe eyedropper from frozen captures; formats HEX/RGB/HSL/OKLCH; APCA + WCAG contrast vs a second sampled color; reference Pika (MIT) for conversions.
- **M23 Background removal** (04 §6, 03 §3 P3): VNGenerateForegroundInstanceMaskRequest in HelperTools → subject-lift command in the editor.
- **M24 Multi-image composition + .kadr polish** (03 §3): drag additional captures into the canvas; project save/reopen from history.
- **M25 HDR + macOS 15+ niceties** (04 §4.1/4.3): HDR screenshot/record presets behind availability; RecognizeDocumentsRequest "copy as table".

---

## Appendix A — `CLAUDE.md` for the repo root

```markdown
# Kadr — agent rules

You are working on Kadr, a free open-source native macOS screen-capture
app. The specs in docs/ are authoritative: 02=PRD, 03=feature specs (behavior
+ acceptance criteria), 04=architecture (module layout, recipes, decision log).
When a task references a doc section, read it before writing code.

## Non-negotiable rules
1. ZERO NETWORK: no import Network, no URLSession, no sockets anywhere except
   the Sparkle update integration. There are no upload/share/URL features —
   sharing is drag-and-drop + NSSharingServicePicker only. CI enforces this.
2. RAM budget: agent idles <30 MB, zero timers, 0.0% CPU. The agent never
   links EditorUI or VisionServices. Vision/encoders run in HelperTools
   (self-terminating XPC); the editor is a separate app that dies on close.
3. All screen capture via ScreenCaptureKit only — never CGWindowListCreateImage
   or CGDisplayCreateImage. All SCK calls stay in the agent process (TCC).
4. AppKit owns windows (NonActivatingPanel recipes in docs/04 §5); SwiftUI is
   allowed only inside NSHostingView content that is deallocated on close.
   Nothing SwiftUI in the selection overlay's mouse path — CALayer only.
5. Swift 6 language mode, strict concurrency, no new DispatchQueues outside
   SCK-required handler queues. @MainActor UI, actors for engines,
   AsyncStream at delegate boundaries.
6. Coordinates go through Shared.Geometry typed wrappers (ScreenPoint,
   PixelRect) — never raw CGRect math across the AppKit/CG flip or
   point/pixel scaling.
7. Every user-visible behavior must match docs/03; if a spec is ambiguous,
   note the interpretation in the PR description rather than inventing UI.
8. Add os_signpost to any path with a PRD §8 budget; never remove one.
9. Tests: pure packages get unit tests with real coverage; geometry and
   parsers are table-driven; perf budgets are tests, not comments.
10. Dependencies: additions require justification against docs/04 §12;
    KeyboardShortcuts and Sparkle and GRDB are pre-approved. AGPL/BUSL code
    (QuickRecorder, Capso) is READ-ONLY reference — never copy it.

## Workflow
- One milestone per branch (docs/06 defines them). Run swiftlint,
  swiftformat, Scripts/check-layering.sh, and package tests before declaring
  done. Verify the milestone's "Done when" list and say which items you
  could not verify in-sandbox (e.g., TCC-gated integration tests).
```

## Appendix B — prompt patterns that keep quality high

- **Always anchor:** start prompts with "Read docs/<file> §<n>" — the specs contain the details (options, edge cases, accepts) deliberately omitted from prompts to avoid drift.
- **Demand the accepts:** end sessions with "walk through the milestone's Done-when list and state pass/fail/unverifiable for each" — it turns the acceptance criteria into the agent's own checklist.
- **Perf paranoia:** after any milestone touching the agent process, re-run the M10 harness prompt: "Run the perf suite and Instruments-verify zero idle wakeups; fix regressions before anything else."
- **Review pass:** for gnarly milestones (M2, M7b, M12, M15), a second session with: "Adversarially review the last merge against docs/03's accepts and docs/04's rules; list concrete violations with file:line, then fix them" catches what the build can't.
- **When stuck on macOS APIs:** have the agent consult the reference repos from doc 04 §13 (Snapzy BSD-3, TRex/Pika MIT, Apple CaptureSample) — permissively-licensed, purpose-matched examples beat guessing.
