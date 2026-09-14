# Feature Specifications — Kadr

> Detailed behavior specs for every feature. Each section gives: purpose, interaction flow, functional details, edge cases, and acceptance criteria. Phase tags refer to the roadmap in `02-prd.md` §5.
> Implementation notes live in `04-swift-architecture.md`; this doc defines *what*, that doc defines *how*.

---

## 1. Capture modes

### 1.1 Area capture (P1)

**Flow:** hotkey (default ⌘⇧4-style, user-configurable) → screen freezes (each display captured once and shown in a full-screen overlay < 100 ms) → crosshair cursor with live **magnifier loupe** (8× pixel zoom, current pixel color + coordinates) → drag to select; dimension badge (`W × H` in points and pixels) follows the selection → release to capture → Quick Access Overlay appears.

Details:
- Dimmed backdrop with a clear "hole" over the selection (even-odd fill).
- While selecting: hold **Space** to move the selection; **arrow keys** nudge by 1 px (⇧ = 10 px); type numbers to set exact W×H; **⌥-drag** resizes from center; **aspect lock** via ⇧-drag; **Esc** cancels. **F** captures this display at full size (not while the eyedropper is on). Idle overlay shows a teaching line (drag / W for a window / F for this display); hide it in Settings → Capture.
- After mouse-up but before commit (optional "confirm mode", off by default): handles for resize, Enter/click-outside to commit.
- **Remember last region**: hotkey "capture previous area" (P1) repeats the exact last rect on the same display instantly, no UI. Opening area capture on that display also draws the last rect as a dashed ghost until a new drag starts.
- **Snapping (P2):** selection edges snap to detected window frames and screen edges (from `SCShareableContent` window geometry); toggleable.
- Freeze-frame means moving content (video, animations) is captured exactly as seen at hotkey time — this doubles as CleanShot's "Freeze screen" feature for free.

Edge cases: multi-display drags stay per-display (v1) — a selection cannot span displays; mixed Retina/non-Retina scale factors resolved per display; hotkey while overlay already open re-freezes; menu bar & our own windows excluded from the frozen image.

**Accept:** overlay visible < 100 ms after hotkey on a 2-display M1; captured pixels are 1:1 with what the user saw (no post-freeze changes leak in); dimension badge matches output size; Esc leaves no residue (windows deallocated).

### 1.2 Window capture (P1)

**Flow:** hotkey or mode-switch from area overlay → hovering highlights the window under cursor (tint + outline, window title shown) → click captures that window **cleanly via ScreenCaptureKit desktop-independent window filter** — i.e., not occluded by overlapping windows, at full backing resolution.

Options (in settings and via ⌥ modifier at click time):
- Shadow on/off; **transparent background** (window alpha preserved, PNG) or solid color / desktop / custom image behind it (background applied compositionally at export, so it stays editable in the editor, P2).
- ⇥ cycles windows of the same app; hold ⌘ to pick child windows/panels.

**Accept:** occluded windows capture unoccluded; shadow toggle honored; transparent PNG has real alpha; works on other-Space windows listed by SCK where the OS allows.

### 1.3 Fullscreen / display capture (P1)

Hotkey captures all displays (one file per display, or stitched — setting), or a chosen display via the All-in-One HUD. Silent (no overlay), instant, cursor optionally included. On a notched MacBook, fullscreen stills of an app that covers the display drop the camera strip (setting, on by default). From the area overlay, **F** captures the display under the pointer.

### 1.4 All-in-One capture HUD (P2)

One hotkey opens a compact control strip (like ⇧⌘5 / CleanShot All-in-One): mode buttons (area/window/screen/record/scrolling/OCR), options popover (timer, save target, audio for recording), and the last-used mode pre-armed. Esc dismisses. This is the discoverable path; hotkeys are the fast path.

### 1.5 Self-timer (P1)

3/5/10 s presets (custom seconds field). On-screen countdown badge (top-right, non-interactive, excluded from capture); Esc cancels. Works with area (uses remembered/pre-drawn region), window, fullscreen.

### 1.6 Scrolling capture (P2)

The hardest feature; ship in two tiers:

- **Tier 1 — assisted:** user selects region → presses Start → scrolls the target content themselves at any pace (vertically or horizontally; CleanShot §4.8) → frames are grabbed continuously (SCStream at low fps) → on Stop, frames are stitched by feature-matching overlap. Progress preview shows the growing strip. Works in any app, no Accessibility permission.
- **Tier 2 — auto-scroll:** we synthesize scroll events (CGEvent) into the target window until content stops changing or user stops. Requires Accessibility permission (asked only when first used, with an explainer). Per-app quirks (momentum scrolling, lazy-loading pages) handled by settle-detection between scroll steps. Direction is chosen in Settings or the capture HUD before the first frame lands.

Output goes to the editor scrolled-canvas mode. Failure mode: if stitching confidence is low, show seams and offer "keep anyway / retry / export frames".

**Accept:** correct stitch on: Safari long page, VS Code file, Slack thread, Finder list view, Terminal scrollback (the classic pain cases); no duplicated or missing bands at seams; memory stays bounded (stitch tiles stream to disk beyond ~16k px tall).

### 1.7 OCR — Capture Text (P1)

**Flow:** hotkey → same area-selection overlay (tinted differently + `TEXT` badge) → release → Vision text recognition on the selected pixels → recognized text **copied to clipboard** + toast preview with character count → optional popup editor to review before copy (setting).

Details: language auto-detect (`automaticallyDetectsLanguage`), accurate mode; preserves line breaks (toggle: preserve / collapse to spaces); QR/barcode payloads decoded and offered ("Open link / Copy"); result also stored with the capture's history record (P2) to power search (P3). Settings → Capture can open a review window instead of the toast: editable text, word/character counts, table copy, and QR actions. The clipboard still receives the text immediately.

**Accept:** ≥ Apple-Live-Text parity (it's the same engine); < 1 s for a typical region on M1; no network.

### 1.8 Screen recording (P2)

**Flow:** hotkey/HUD → region/window/display selection (same overlay grammar as stills) → control strip appears (mic toggle + input picker, system-audio toggle, camera toggle, countdown setting) → Record → menu-bar icon becomes a red timer (click = stop; menu = pause/cancel); optional floating stop button. On stop → overlay thumbnail with "Trim / Save / Copy / GIF / Delete".

Technical envelope: SCStream capture at native resolution, 60 fps default (configurable 24/30/60); HEVC (hardware) default with H.264 option for compatibility; mic as separate track (P2, macOS 15 in-SCK mic when available, AVCaptureSession fallback on 14); system audio via SCK `capturesAudio` (no driver); optional mono mixdown of each audio track; pause/resume; auto-DND during recording (Focus API); click highlighting (circle pulse on clicks, rendered into the stream via overlay compositing); cursor show/hide; keystroke overlay (P2, rendered from a CGEventTap *only while recording*, permission-gated, showing ⌘-combos or all keys). The floating control bar shows an audio-level meter from the buffers being written, and a "Mic silent" notice if the microphone is on but nothing has reached it after a couple of seconds.

**GIF export:** trim first, then encode ≤ 50 fps, palette-optimized (gifski-quality target), size estimate shown before export.

**Webcam overlay (P2.5):** AVFoundation capture into a movable/resizable PiP circle/rounded-rect composited into the recording.

**Accept:** 1080p60 HEVC < 15% CPU on M1; A/V drift < 1 frame over 10 min; pause/resume produces gapless file (every audio track survives a stitch, not just the first); recordings recoverable after crash (writer segments finalized incrementally).

### 1.9 Speech in the studio (docs/13)

On-device only. Transcription runs in the XPC helper so Speech.framework never loads in the agent. The audio handed to the engine is extracted PCM (16 kHz mono), preferring the microphone track when the file has one.

**Tidy Speech.** Inspector → "Remove filler words and long pauses". The edited-timeline guard runs *before* transcription. The result is a **review list** of labelled cuts ("um" at 0:14, "2.3 s pause" at 1:02) with per-cut toggles and a preview seek. Applying is a second step. A plan that would remove more than ~40% of the timeline requires explicit confirmation. Zero-timestamp transcripts are refused. Cuts become clip boundaries (undoable; footage untouched).

**Transcript.** Persisted as `transcript.json` in the `.kadrrec` package, keyed on the audio's content hash. Reopening reuses it. A panel beside the timeline: click a word to seek, select a sentence to cut it, search by text. Two-track recordings are labelled "You said" / "The app said". Chapter marks from long pauses.

**Captions.** Optional burned-in captions in the studio's existing caption style; SRT and VTT written beside an export when a transcript exists.

**Audio in the studio.** Mute silences preview and export. Mix to mono downmixes stereo on export (and on an audio-only export), matching the record-time mono option.

**Language.** A picker; changing engine or model rewrites an unsupported choice rather than failing later. On macOS 14/15, if on-device dictation is missing, the inspector points at System Settings ▸ Keyboard ▸ Dictation instead of showing a Tidy button that can never work.

**Model download.** Separate button from Tidy. Optional, cancellable, with a disk-space precheck. The studio works without it.

**Progress and cancellation.** Transcription and model download both show progress, can be cancelled, and closing the window warns if either is running.

**Teleprompter "Follow my voice".** Audio buffers from the agent → helper → word hypotheses. The prompter advances only on words that survive two consecutive hypotheses, and never scrolls backwards on a retraction. The Pace slider stays enabled as the fallback.

**Accept:** Tidy on a 10-minute narrated recording with a mic track produces a review list and never silently removes 90% of the timeline; a transcript is produced from extracted PCM on macOS 14, 15 and 26; the mic track survives a pause; `tidySpeech` tests would fail if T-C1/T-C2/T-C3 were reintroduced; `otool -L` on the agent still shows no Speech.

---

## 2. Quick Access Overlay (P1) — the signature surface

**Behavior:** after every capture, a thumbnail card (default bottom-left, configurable corner) slides in on the display where capture happened (setting: always primary). Cards stack (max 5 visible, older collapse behind). The overlay is a non-activating floating panel: it never steals focus, appears over full-screen apps, on all Spaces.

Per-card interactions:
- **Drag out** → real file promise drag (works into Slack/Mail/Finder/browsers). Dragging out removes the card (setting).
- Single click → expand action row: **Copy · Save · Save As · Annotate · Pin · OCR · Share sheet · Delete** (Save As is opt-in via Overlay ▸ Card layout; it always opens a save panel). Double-click → open editor directly. Auto-saved cards (not staged) show a **Trash** button on hover beside Hide (CleanShot §6.2). Context menu: Rotate 90°, Flip Horizontal, Flip Vertical, Scale Retina to 1× (CleanShot §6.2 / §8.2).
- Hover shows filename, dimensions, size, the card's corner actions, and a close (×) that **hides the card without deleting**. ⌫ deletes; Esc hides; **Return** saves and closes (configurable in Overlay settings); Space Quick Looks; while the pointer is over a card, ⌘C copies, ⌘S saves, ⌘E annotates (trim for a recording), ⌘P pins, and ⌘W closes (local monitor only, so the front app keeps those keys otherwise). Swipe toward the docked edge dismisses; swipe toward the screen edge tucks the stack into a peek tab.
- Auto-dismiss timer (default off/∞; options 5/10/30 s). Hovering or dragging **pauses** the timer and retries shortly after the pointer leaves; opening the editor, studio, or trim **keeps that card** until the user hides it. **Dismiss ≠ delete**: files still land per save policy; "Restore recently closed" (menu + hotkey) brings the last N back. When several cards stack, the newest shows a small accent dot (CleanShot §6.3). **Save All** and **Close all** (menu, hotkey, peek-tab ×) dismiss cards **one at a time** so the stack reflow animates instead of jumping (CleanShot §6.3 / 4.7.5).
- Opening the editor tucks the stack into a **peek tab** (count + ×) in the same corner. Click the tab to bring the cards back even while the editor is still open; × dismisses every card. A new capture expands the stack so the new card is seen.
- Default action on capture is configurable: copy to clipboard, save to folder, both, overlay-only (file goes to history staging and is finalized on first action — keeps Desktop clean), or **ask where to save** (a save panel as soon as the capture lands; the file stays staged until the panel confirms). Overlay Save can also ask every time (General → Ask where to save from the overlay). **Save As** on a card always asks, even when silent save is on (CleanShot §6.2).

**Accept:** overlay never takes key focus from the frontmost app; drag-out delivers a correctly named file (no `Untitled` / tmp names); stacking never overlaps the Dock; VoiceOver can reach every action.

---

## 3. Annotation editor (P1 core, grows through P3)

Opens in **its own process** (see doc 04) as a normal resizable window; multiple editors may be open.

**Model:** the base image is immutable; every annotation is a vector object (type, geometry, style, z-order) in an ordered stack → unlimited undo/redo, select/move/edit any object later, lossless re-export. "Flatten" only happens at export.

**Tools (P1):**
- **Select/move** (click, marquee, ⌘-click multi-select; eight resize handles on the selection box — corners and edges, sized in view points so they stay hittable when zoomed out; a lone arrow, line or length-measurement gets path handles at its terminals instead, plus a midpoint on arrows to bend the curve; ⇧ on a corner locks aspect, ⇧ on a path end snaps to 45°; arrow-key nudge).
- **Arrow** — straight + curved (drag midpoint); 3 head styles; smart default color (auto red/contrasting).
- **Shapes** — rect, rounded rect, ellipse, line; fill/stroke/none; stroke width via the inspector slider (presets 2/4/6/10/16 sit in the 1–32 pt range); fill opacity when filled.
- **Freehand pencil** with smoothing; **Highlighter** (multiply-blend stroke).
- **Text** — inline editing, 7 style presets + custom (font/size/weight/color/background pill). A click places a box and opens the editor; a click on existing text edits it.
- **Blur / Pixelate / Erase** — rectangular region; pixelate uses randomized displacement (defeats de-pixelation of predictable grids); erase fills with the colour sampled from the region's edge so UI chrome disappears; irreversible at export (actually re-rendered from blurred pixels, not an overlay that can be removed from the PNG — security-reviewed).
- **Counter badges** — auto-incrementing numbered circles; formats 1 / I / A / a; drag to reorder renumbers.
- **Crop** — non-destructive; aspect presets; expand-canvas allowed (for padding). Expanded padding is filled from the capture's edge colour at export, not hard-coded white.
- **Lock objects** — toolbar lock or ⇧⌘L keeps existing annotations from moving while you draw (CleanShot §8.1). Settings ▸ General can turn this on by default for new editor sessions.
- **Object shadows** — Settings ▸ General can disable drop shadows on inserted images (CleanShot §8.2 / §21).
- **Tool size** — `` ` `` / `+` (or `-`) changes the armed tool's stroke width, or text size for the text tool (CleanShot §8.2).
- **Tool hand-off:** after a one-shot tool lands (arrow, shape, line, text once the in-place editor commits, blur/pixelate/erase), the pointer returns to Select so the new annotation can be moved immediately. Pencil, highlighter, and counters stay armed — a numbered badge is one of a sequence. Crop is a mode until **Done**. Picking a drawing tool from the toolbar clears the current selection.
- Style system: last-used style per tool remembered; per-tool color/size in a floating inspector; global theme colors.
- **Canvas drawing:** annotation tools apply to the whole canvas, including beautify padding around the screenshot — not only the capture itself. Coordinates stay image-relative so a crop still makes sense; the padding is just more of that plane.
- **Inspector sliders:** every numeric control is a scrub track with the label inside it and a typed value field to the right (suffixes: "45%", "12 px", "30°", "1.5×"). Clicking the track sets the value at that position; hover reveals ticks; signed ranges (tilt, pan, roll) detent on zero. Arrow keys step one displayed unit.

**P2 additions:** Spotlight (dim outside a region), Smart Highlighter (Vision word-boxes snap), sticker/emoji, image insert (multi-image composition), background/beautify panel (padding, gradient/solid/image backdrop, corner radius, shadow, aspect presets, auto-balance), resize/downscale export panel, rotate / flip horizontal / flip vertical (CleanShot §8.2).

**P3 additions:** auto-redaction assistant (pre-runs OCR + patterns for emails, phone numbers, API-key shapes, credit cards; highlights candidates; one click blurs all), background removal (subject lift), measurement overlay & pixel ruler, OKLCH/APCA color picker eyedropper, `.kadr` re-editable project file (zip: base PNG + JSON command list).

**Export:** ⌘C copy flattened; ⌘S save next to the original when **Keep the original file** is on (General ▸ Annotate), or overwrite the capture when it is off (CleanShot §7); ⌘⇧S Save As (format picker: PNG / JPEG / HEIC / `.kadr`); ⌘⌥S Save Project; File ▸ Print (⌘P, tall scrolling captures paginate across sheets); drag-out from title-bar proxy; "Copy without annotations" alt-action. The toolbar Save button is the silent write (CleanShot's ⌥+Save).

**Accept:** 60 fps object dragging on a 5K capture; undo depth ≥ 100; blur regions unrecoverable in exported files; editor process exits fully when last window closes (RAM returns to agent baseline).

---

## 4. Pinned screenshots (P1)

Any capture (from overlay, editor, or history) can be **pinned**: a borderless always-on-top window showing the image at captured size (drag corners to scale; ⌥-scroll zoom; double-click = 100%).

- Opacity slider (⌥-scroll or menu, 20–100%); **click-through mode** (⌘⌥L) making it a pure reference layer; arrow-key positioning; appears on all Spaces; multiple pins.
- Pin menu (right-click): copy, save, annotate, OCR, close. "Close all pins" global command. **Pin Clipboard** (menu + hotkey) pins an image on the pasteboard, or draws plain/RTF/HTML text as a card and pins that.
- Pins persist across app restarts (P2, from history).

**Accept:** pin windows never take focus on show; click-through verified over interactive apps; 20 pins ≤ 40 MB added RSS (downsampled backing images, full-res reloaded on demand).

---

## 5. History & library (P2), search (P3)

- Every capture recorded: file reference, thumbnail, type, dimensions, app under capture, timestamps, OCR text (lazy).
- **Menu strip:** last 8 captures as thumbnails right in the status-item menu — click to re-open overlay card.
- **History window:** grid browser with type/date filters, drag-out, batch select, reveal-in-Finder, delete (with file), storage usage meter. Retention setting: keep forever / 30 days / 7 days / session-only; size cap with LRU eviction.
- **P3 — search:** full-text over OCR'd content + window/app names ("that screenshot of the stripe error last week"). Fully local SQLite FTS index; indexing runs only on idle power + only for history-retained items; opt-out.

**Accept:** history browser cold-opens < 400 ms @ 1k items (thumbnails paged from disk); deleting from history removes files; index adds zero agent idle cost (indexer runs in editor/helper process, exits when done).

---

## 6. Sharing — drag-and-drop only, everything local (P1)

There is deliberately **no sharing infrastructure**: no hosting, no upload targets, no share-by-URL, no accounts. The app's sharing model is the thing macOS already does perfectly:

- **Drag-and-drop is the primary path** — from the Quick Access Overlay card, the editor's title-bar proxy icon, a pinned window, and any history item. Drags are `NSFilePromiseProvider` file promises, so the receiving app (Slack, Mail, Figma, browsers, Finder) materializes a properly named file even when the capture only exists in staging.
- **Clipboard is the second path** — configurable default action "copy on capture"; ⌘C anywhere copies the flattened image.
- **Native share sheet** (`NSSharingServicePicker`) from overlay/editor/history — AirDrop, Messages, Mail, and whatever share extensions the user has installed. The OS handles delivery; the app never talks to a server.
- Consequence worth advertising: **nothing you capture ever leaves the Mac.** The app contains zero networking code, and reaches the network in exactly two places, both enforced by CI: Sparkle's update check, and — only if you ask for it — asking macOS to install a speech model so the studio can offer to cut filler words. The studio works without that model, transcription is on-device either way, and no recording is ever uploaded. Nothing to configure, nothing to trust.

---

## 7. Desktop hygiene & precision utilities (P2)

- **Hide desktop icons** (and widgets): toggle from menu/HUD/URL scheme; auto-hide while recording (setting); temporary wallpaper override (solid color/image) during capture.
- **Crosshair precision mode:** full-screen crosshair guides + coordinates while selecting (toggle in overlay with `C`).
- **Screen freeze** as a standalone toggle (freeze display(s) to inspect moving UI, then capture normally) — the P1 area-capture freeze exposed as its own command.

---

## 8. App shell & UX chrome

### 8.1 Menu bar item (P1)
Template-style icon; states: idle / capture armed / recording (red + timer). Left-click menu: capture actions with hotkey hints, last-captures strip (P2), pins, history, settings, check-for-updates, quit. Drag a file *onto* the icon → opens in editor (P2). ⌥-click = All-in-One HUD.

### 8.2 Onboarding (P1)
First launch: 3 screens max. (1) What it does + the main hotkeys; (2) **Permissions** — Screen Recording required; Accessibility, Input Monitoring, Microphone and Camera optional. Compact rows with live status (Allow / Open Settings / Allowed / Restricted), deep-links, live-detect on return from System Settings, resume after a grant that needs a relaunch, and an honest note about macOS 15’s monthly re-confirmation; (3) defaults choice: clipboard-first vs file-first, save folder, launch-at-login opt-in, plus a practice image that opens the editor with no capture. Total < 2 min; every screen skippable. Settings ▸ Permissions is the same recovery UI for people who skipped.

### 8.3 Settings (P1, grows)
Panes: General (login item, default action, save folder, optional ask-where-to-save from the overlay, filename template `{app}-{date}-{time}`, format, Retina downscale, optional convert-to-sRGB on save), Permissions (live TCC status and recovery for Screen Recording, Accessibility, Input Monitoring, Microphone and Camera), Shortcuts (recorder UI for every command), Overlay (corner, size, timeout, stacking, optional always-show actions), Capture (cursor, shadow, snapping, auto-crop notch, overlay teaching hints, OCR review window), Recording (P2), History (P2), Advanced (URL scheme/CLI install, reset). Settings window is a normal app-style window (works around LSUIElement focus quirks per doc 04).

### 8.4 Automation (P2)
- URL scheme: `kadr://capture-area?action=copy|save|annotate|pin&x=&y=&w=&h=`, `capture-window`, `capture-fullscreen`, `capture-text`, `record-screen?fps=`, `pin?filepath=`, `toggle-desktop-icons`, `open-history`, `open-settings?tab=` … (CleanShot-verb alias table for Raycast migration).
- CLI `kadr` (symlinked helper): same verbs, stdout paths/text, `--json`; exits non-zero on cancel.
- Shortcuts.app actions wrapping the same command layer.

---

## 9. Cross-cutting requirements

- **Input latency:** all overlay interactions tracked at 120 Hz on ProMotion; no SwiftUI layout in the mouse-move path of the selection overlay.
- **Multi-display:** every feature correct on mixed-DPI, mixed-refresh, hot-plugged displays; Spaces & full-screen apps respected (`.canJoinAllSpaces`, `.fullScreenAuxiliary`).
- **Accessibility:** full keyboard operation of overlay/editor; VoiceOver labels on all controls; reduced-motion honored (no slide animations); contrast-safe default annotation colors.
- **Interruptions:** display sleep/lock/log-out during recording finalizes the file safely; TCC revocation mid-use degrades with a clear re-grant prompt, never a crash.
- **Files:** atomic writes; never overwrite (auto-increment); filename template engine; correct EXIF/DPI metadata (144 dpi tag on Retina, color profile embedded). Optional convert-to-sRGB on save so browsers match this Mac; off by default so a P3 capture keeps its profile.
- **No data exfiltration surface:** agent binary links no networking beyond Sparkle; hard rule enforced by module layering (doc 04) + a CI check that greps the agent's linked frameworks.

## 10. Feature ↔ competitor traceability

| Our feature | Matches | Beats |
|---|---|---|
| Quick Access Overlay | CleanShot signature | open-source first; never-touch-disk staging mode |
| Freeze-frame area capture + magnifier | CleanShot (freeze, magnifier), Shottr speed | freeze is default, not a mode |
| Clean window capture w/ transparent bg | CleanShot | — |
| OCR + QR | CleanShot, Shottr | history-search integration (P3) |
| Recording + system audio, no driver | CleanShot, QuickRecorder | permissive-license OSS |
| GIF export | CleanShot, Kap | — |
| Scrolling capture | CleanShot, Shottr, Snagit | assisted mode works w/o Accessibility permission |
| Pin + click-through | CleanShot, Shottr, ScreenFloat | — |
| Beautify backgrounds | CleanShot, Xnapper | — |
| Auto-redaction | Xnapper (unique among suites) | open + auditable |
| Pixel ruler / OKLCH picker | Shottr (unique) | integrated with annotation |
| OCR-searchable local history | ShotBase ($156/yr, AI) | free, no account, no model download |
| URL scheme + CLI + Shortcuts | CleanShot (URL only) | CLI + JSON output |
| DnD-only local sharing, zero network code | — (nobody commits to this) | stronger privacy stance than even Shottr/ScreenCap |
| Perf budgets in CI | Shottr (marketing claim) | published, enforced, reproducible |
