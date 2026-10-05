# Feature Specifications — Kadr

> Detailed behavior specs for every feature. Each section gives: purpose, interaction flow, functional details, edge cases, and acceptance criteria. Phase tags refer to the roadmap in `02-prd.md` §5.
> Implementation notes live in `04-swift-architecture.md`; this doc defines *what*, that doc defines *how*.

---

## 1. Capture modes

### 1.1 Area capture (P1)

**Flow:** hotkey (default ⌘⇧4-style, user-configurable) → screen freezes (each display captured once and shown in a full-screen overlay < 100 ms) → crosshair cursor with live **magnifier loupe** (8× pixel zoom, current pixel color + coordinates) → drag to select; dimension badge (`W × H` in points and pixels) follows the selection → release to capture → Quick Access Overlay appears.

Details:
- Dimmed backdrop with a clear "hole" over the selection (even-odd fill).
- A drag shorter than 4 pt on either side is a click, not a selection: the overlay stays up and nothing is captured.
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

"The window under cursor" means the **frontmost** one there: the pick list is ordered by the window server's stacking order (ScreenCaptureKit's list is not in z-order), fully transparent windows and Kadr's own overlay panels are left out.

**Accept:** hovering overlapping windows always highlights and captures the one on top; occluded windows capture unoccluded; shadow toggle honored; transparent PNG has real alpha; works on other-Space windows listed by SCK where the OS allows.

### 1.3 Fullscreen / display capture (P1)

Hotkey captures the active display, all displays (one file per display, or stitched — setting), or a chosen display via the All-in-One HUD. Silent (no overlay), instant, cursor optionally included. “Silent” means no selection UI — a capture sound may still play if that setting is on. On a notched MacBook, fullscreen stills trim the empty camera strip only when those pixels are actually black (setting, on by default); a fullscreen shot of an app that covers the menu bar is left intact. From the area overlay, **F** captures the display under the pointer. The clipboard for an all-displays capture is the active display.

### 1.4 All-in-One capture HUD (P2)

A click on the menu-bar icon — or ⇧⌘2, beside the system's ⇧⌘3/4/5 — opens a compact floating island (like ⇧⌘5 / CleanShot All-in-One): mode buttons (area A, window W, screen F, record R, GIF G, scrolling S, OCR T, colour P — each key shown as a keycap in the button's hover tooltip and working while the island is up; Close shows esc), options (timer, aspect, save target, audio for recording), a **Tools** menu whose rows show their keys (capture previous area L, self-timer capture D, macOS picker K, freeze screen Z, hide desktop icons H, pin clipboard V, open capture folder O, history Y), and the last-used mode pre-armed. Esc dismisses. The island is the primary way into every capture; global hotkeys are the fast path for the few commands people fire blind. ⇧⌘2 is a toggle: it closes the island when it is open, and from the recorder it goes back to the island. Record morphs the island into the recorder bar; when the recorder was opened that way it shows a **back** button (and Esc goes back), which fades the island in again on the same spot instead of closing everything. The recorder answers keys too, so a recording can be started without the mouse: **A** area, **W** window, **F** full screen (the island's own letters, meaning the same thing), **M** microphone, **S** system audio, **C** camera, **H** click highlights, **K** keystroke overlay, **T** teleprompter, **Return** records (ignored while nothing is armed), **Esc** goes back or closes. Each key is shown in its control's hover tooltip.

### 1.5 Self-timer (P1)

3/5/10 s presets (custom seconds field). On-screen countdown badge (top-right, non-interactive, excluded from capture); Esc cancels. Works with area (uses remembered/pre-drawn region), window, fullscreen.

### 1.6 Scrolling capture (P2)

The hardest feature; ship in two tiers:

- **Tier 1 — assisted:** no freeze and no drawing — a **live, adjustable frame** appears around the window under the pointer, or a centred area, with the rest of the screen dimmed. It opens at no more than ~72% of the visible screen even when the window under the pointer is maximised, because a frame whose edges are the screen's edges has nothing to grab; and the last frame on each display is remembered **across launches**, restored only while it still fits that screen. Eight white handles resize it (corners and edge midpoints, same treatment as the editor's crop box) and a full-width **bar above the frame** moves it — a window's title bar rather than the 56×16 grip that used to sit on the very line people were trying to grab. The inside and outside pass clicks and scrolling through, so the page can be scrolled into place while the frame is set. A panel below the frame (inside it when there is no room) shows the pixel size and **Start Scrolling Capture**; Return starts and Esc cancels. On Start the frame locks and stays, dimmed around → scrolls the target content themselves at any pace (vertically or horizontally; CleanShot §4.8) → frames are grabbed continuously (SCStream at low fps) → on Stop (Return, or Esc — Esc while capturing finishes rather than discards, since the user is working in the page and an Esc meant for it must not destroy the capture; only the HUD's Cancel button discards), frames are stitched by feature-matching overlap. Progress preview shows the growing strip. Works in any app, no Accessibility permission.
- **Tier 2 — auto-scroll:** we synthesize scroll events (CGEvent) into the target window until content stops changing or user stops. Requires Accessibility permission (asked only when first used, with an explainer). Per-app quirks (momentum scrolling, lazy-loading pages) handled by settle-detection between scroll steps. Direction is chosen in Settings or the capture HUD before the first frame lands. **Auto Scroll** is a button, in two places: on the staging panel before the capture starts (⌥↩), and in the running HUD, where it also hands the scrolling back ("Scrolling — Take Over") without ending the capture. A step is capped at 60% of the frame along the scrolling axis, whatever Settings asks for, so every frame overlaps the last one enough to stitch; each step is delivered as pulses of at most 40 pt one display frame apart, so the target scrolls rather than flicking past with momentum; and each step waits for a frame that actually arrived before judging the page, so a slow frame is not mistaken for the end of the page. It stops when two consecutive fresh frames have not moved.

Output goes to the editor scrolled-canvas mode. Failure mode: if stitching confidence is low, show seams and offer "keep anyway / retry / export frames".

**Accept:** correct stitch on: Safari long page, VS Code file, Slack thread, Finder list view, Terminal scrollback (the classic pain cases); no duplicated or missing bands at seams; memory stays bounded (stitch tiles stream to disk beyond ~16k px tall).

### 1.7 OCR — Capture Text (P1)

**Flow:** hotkey → same area-selection overlay (tinted differently + `TEXT` badge) → release → Vision text recognition on the selected pixels → recognized text **copied to clipboard** → a toast in the corner of that display saying how many **lines** were copied (as the recogniser saw them, not as the clipboard string is folded), the character count under it, and the first couple of lines as evidence. It carries **Edit…** (opens the review window), **Copy as Table / Markdown** when a table was found, and **Open / Copy Link** for a QR payload that is a URL; it sizes itself to its content and goes on its own after 5 s. The review window is opt-in — Settings ▸ Capture ▸ "Always open a review window" — because the next thing anyone does after Capture Text is paste, and a window in front of that has to be dismissed first.

Details: language auto-detect (`automaticallyDetectsLanguage`), accurate mode; preserves line breaks (toggle: preserve / collapse to spaces); QR/barcode payloads decoded and offered ("Open link / Copy"); result also stored with the capture's history record (P2) to power search (P3). Settings → Capture can open a review window instead of the toast: editable text, word/character counts, table copy, and QR actions. The clipboard still receives the text immediately.

**Accept:** ≥ Apple-Live-Text parity (it's the same engine); < 1 s for a typical region on M1; no network.

### 1.8 Screen recording (P2)

**Flow:** hotkey/HUD → region/window/display selection (same overlay grammar as stills) → for a region, the area stays lit with the rest of the screen dimmed and a red **Record** button inside it (Return records, Esc clears the area and re-arms the screen) → control strip appears (mic toggle + input picker, system-audio toggle, camera toggle, countdown setting) → Record → menu-bar icon becomes a red timer (click = stop; right-click, ⌃-click or ⌥-click = the menu, with pause/cancel); optional floating stop button. On stop → overlay thumbnail with "Trim / Save / Copy / GIF / Delete".

Technical envelope: SCStream capture at native resolution, 60 fps default (configurable 24/30/60); HEVC (hardware) default with H.264 option for compatibility; mic as separate track (P2, macOS 15+ only, through ScreenCaptureKit's own microphone capture; on macOS 14 the microphone controls are hidden rather than offered and silently ignored — an AVCaptureSession fallback was dropped because it would put a second capture clock beside SCK's that nothing in CI can exercise); system audio via SCK `capturesAudio` (no driver); optional mono mixdown of each audio track; pause/resume (a running take pauses itself when the Mac sleeps or the lid closes, and on wake the bar says so and waits for Resume — nothing is recorded while the screen is off); no automatic Do Not Disturb — macOS has no supported API for an app to set a Focus, so Settings ▸ Recording says plainly "Turn on Do Not Disturb in Control Center before recording" instead of offering a toggle that would do nothing (a later opt-in may run a user-chosen Shortcut at start and stop); click highlighting (circle pulse on clicks, rendered into the stream via overlay compositing); cursor show/hide; keystroke overlay (P2, rendered from a CGEventTap *only while recording*, permission-gated, showing ⌘-combos or all keys). The floating control bar shows an audio-level meter from the buffers being written, and a "Mic silent" notice if the microphone is on but nothing has reached it after a couple of seconds. A microphone the take had to go without (unplugged or not permitted) is announced at start — in the notch too, which expands to show it — and a "no microphone" glyph stays on the bar and the notch for the whole take.

**The trip to Stop is trimmed off the file.** Stopping from Kadr's own controls — the bar's Stop button, the menu's — ends the writer's session early, so the seconds the pointer spent travelling to the button are not in the movie, the way macOS trims its own screen recordings. A hotkey stop, automation and a recording that ends itself trim nothing at all: the pointer went nowhere, and the last second is as much the recording as any other.

The trip is the *budget*, never the answer on its own — it is capped at 2.5 s (a pointer parked on the bar for a minute is a minute of recording, not of travel), a press that lands where the pointer already was removes nothing, and at least a second of recording always survives. Inside that budget, three signals say "this was still the recording" and take their time back, latest wins: **audio above a speech floor** (nothing is cut over someone saying "…and that's it" while reaching for Stop, with 0.4 s after the last sound so a sentence keeps its final consonant), **the last click or keystroke** (plus 0.8 s, because the second after a press is the result of it, which is the thing worth showing), and the floor. What is left is either nothing or a trim worth making: a remainder under 0.2 s is dropped rather than costing a re-encode for something nobody can see. The asymmetry is deliberate — an extra second of a travelling pointer is untidy; three words cut off the end is the recording being useless.

Both tracks end at the same source time, so audio and video stay in step, and the duration reported to the manifest is the length of the file rather than of what was captured, so the studio's timeline and its zooms match the movie.

**Stopping is not part of the recording.** A click on Kadr's own recording controls — the floating bar, the notch island, the menu-bar item — is never written into the telemetry, so it draws no click ripple, adds no keystroke caption, and is not read as an activity worth zooming to. (Reaching for the notch to stop used to end the finished recording with a zoom to the top-right corner.) The rule is the control's rect on screen with 8 points of slop, asked for at the moment of the click because the notch grows under an approaching pointer. Belt and braces for the stops that miss — a hotkey pressed with the pointer over a menu, a stop from another display — the zoom planner also ignores clicks in the last 0.8 s of a recording.

**Notch chrome.** With Settings ▸ Recording ▸ Chrome set to *Menu bar notch*, the controls grow out of the MacBook camera housing instead of floating. One shape across three states — hidden is exactly the hardware notch, compact is menu-bar height with an ear either side, expanded adds the control row below the camera — and the motion is choreographed rather than animated as one picture: the shell is the mass (a looser spring, slight overshoot) and the ears, row and waveform are what land in it (a tighter spring, a beat behind), so it reads as stretching and filling rather than scaling. Starting a recording stretches the shell sideways once and lets it settle; the stretch is horizontal only, because the shell's top edge is the display's edge and lifting it off shows wallpaper where the housing should be. The left ear carries a **live waveform** off the same meter the floating bar uses — five bars that keep their arc in silence, lead from the middle, and rest (dimmed, orange) when the microphone has gone quiet — so a recording that is capturing nothing shows it at a glance rather than at the end. Hovering expands; leaving has a 180 ms grace — long enough to cross the seam between the shell and its tooltip, short enough that leaving reads as a decision rather than as a panel hanging over the work underneath. Closing is its own gesture, not the opening played backwards: a quicker spring, damped hard enough not to spring back a hair's width, and the order reversed — the row fades out ahead of the shell rather than vanishing on the frame the pointer left, so the shell is never an empty black box on its way down. Reduce Motion drops the whole choreography, including the stretch.

**Compressed export:** the studio's export options have a **Compress** switch. It encodes to a quality target instead of an average bit rate, so the still stretches of a screen recording cost almost nothing while text stays sharp; the Quality picker then chooses how far to go (High ≈ identical and about a quarter smaller, Medium ≈ 40% smaller within 1 dB PSNR, Low ≈ half the size with slightly softer text — nothing below that, where the loss becomes visible). Audio drops to 96 kb/s AAC. The dialog shows the output size and an estimated file size ("smaller than about …" when compressing). Not applied to GIF, which ImageIO re-encodes.

**GIF export:** trim first, then encode ≤ 50 fps, palette-optimized (gifski-quality target), size estimate shown before export.

**Webcam overlay (P2.5):** AVFoundation capture into a movable/resizable PiP circle/rounded-rect composited into the recording.

**Accept:** 1080p60 HEVC < 15% CPU on M1; A/V drift < 1 frame over 10 min; pause/resume produces gapless file (every audio track survives a stitch, not just the first); recordings recoverable after crash (writer segments finalized incrementally, stored under Application Support rather than `$TMPDIR`). If the stream dies or the writer fails mid-take, Kadr stops, keeps everything captured so far, and says so. A failed join leaves the segment folder and offers Show in Finder. Sleep is held off while a recording is running.

**Studio controls layout.** Under the timeline, the transport (edit tools · centred playback · cut tools) and the Crop / Inspector / Copy / Share / Export actions sit on one row when they fit, on two rows when they do not, and in a compact form on a narrow preview (edit tools folded into one **Edit** menu, playback keeping frame-step and play, actions as icons). Groups never overlap. Crop mode replaces the row with its own bar rather than covering it. Keys (Space, ←/→, ⌥←/⌥→, ⌘K, ⌘Z, ⇧⌘Z, ⌘I, ⌘E) work in every arrangement, because none of them is declared on a control: the ⌘ ones are menu commands and the bare ones travel the window's responder chain, which also keeps them out of a focused text field.

**Studio inspector.** Four panes behind a segmented control — **Clip** (the clip under the playhead: speed, split, delete; and the selected zoom), **Frame** (the saved look, aspect and fit, crop, canvas, camera bubble), **Effects** (pointer, clicks, zoom motion, shortcut captions) and **Audio** (audio, speech, burned-in captions). Selecting a clip or a zoom brings the Clip pane forward; clearing a selection leaves the panes where they are. Each pane is a grouped form of plain sections: explanation lives in a section footer, never as body text, and a group's controls appear only when the switch that owns them is on. Exclusive choices — backdrop kind, zoom focus — are segmented controls; overlay position is a two-row grid drawn in the proportions of the picture. The chosen pane is remembered per user, not per recording.

**Zooms on the timeline.** The timeline's lanes are labelled in a fixed header column — **Zoom** (with a **+** that adds a zoom at the playhead) and **Clips**. Adding a zoom by hand is one click: hovering empty zoom-lane space shows a dashed "Add zoom" preview of the default zoom (3 s hold plus its moves, stopped by neighbouring zooms and the end of the recording), and a click adds exactly that; dragging sets a custom length instead. Clicking an existing zoom's space selects it; where there is no room the studio says so. The transport's zoom button is labelled "Zoom". The zoom lane shows every recorded click as a dot and, wherever a cluster of clicks has no zoom yet, a dashed **suggested zoom**: click it to add it (it is selected, ready to adjust), right-click to dismiss it for the session. A wand button with a count adds every remaining suggestion without touching zooms placed by hand; "Replace All with Smart Zooms", "Remove Every Zoom", "Show Suggested Zooms" and "Restore Dismissed Suggestions" live in the lane's and the transport's menus. A zoom block shows its aim (pointer / fixed / centre) and magnification, a × on hover removes it, a double-click (or Return when selected) plays it from half a second before, and its context menu can play, disable, re-aim or remove it. Keys on the timeline: **Z** adds a zoom at the pointer (or selects the one already there), **[** / **]** step to the previous / next zoom. The inspector's Clip pane says "Zoom n of m" with previous / next and Play.

**Aiming a zoom.** A zoom added by hand is aimed where the pointer was at that moment — the recorded pointer track is the best evidence of what the user was doing — and adding one opens **Aim Zoom** so that answer is visible and changeable straight away (also reachable later from the inspector's *Aim on Preview…*). Aiming shows the recording **unzoomed** with the cue's frame drawn on it, everything outside it dimmed, its magnification on a pill, and a crosshair where the pointer was when the zoom starts. Drag inside the frame to aim; drag a corner to change how close it goes; the frame stops at the picture's edges, because the render has nothing to show outside them. Aiming anywhere sets the focus to **Fixed** — placing a target is what Fixed means — and the bar under the preview offers *At the Pointer*, *Centre*, *Play* and *Done* (Return or Esc). A cue that follows the pointer has no fixed target, so it cannot be aimed; its bias slider stays in the inspector. Aim mode is a mode, not an edit: nothing about it is saved or undone.

### 1.9 Speech in the studio (docs/13)

On-device only. Transcription runs in the XPC helper so Speech.framework never loads in the agent. The audio handed to the engine is extracted PCM (16 kHz mono), preferring the microphone track when the file has one.

**Tidy Speech.** Inspector ▸ Audio ▸ "Remove Filler Words…". Works after a trim or cut: proposed cuts are subtracted from the current timeline. The result is a **review list** of labelled cuts ("um" at 0:14, "2.3 s pause" at 1:02) with per-cut toggles and a preview seek. Applying is a second step. A plan that would remove more than ~40% of the *edited* timeline requires explicit confirmation. Zero-timestamp transcripts are refused. Cuts become clip boundaries (undoable; footage untouched).

**Transcript.** Persisted as `transcript.json` in the `.kadrrec` package, keyed on the audio's content hash. Reopening reuses it. A panel beside the timeline: click a word to seek, select a sentence to cut it, search by text. Two-track recordings are labelled "You said" / "The app said". Chapter marks from long pauses.

**Captions.** Optional burned-in captions in the studio's existing caption style, wrapping to at most a few centred lines rather than squashing; SRT and VTT written beside an export when a transcript exists. Cues break around 42 characters, 4 seconds, or a 0.9 s silence. The Captions section is always in the inspector; before there is a transcript it offers **Transcribe**, which makes one without proposing any cuts (the same button sits beside Find Cuts…).

**Zooms.** Cues are stored in source time so a cut, trim, speed change or Tidy Speech keeps each zoom on the same footage. Padding around a Presenter card cannot change the export's aspect ratio: the canvas stays at the reframe output and the card shrinks inside it. A 9:16, 1:1 or 4:5 reframe follows the pointer (with a dead zone) so zooms are not cancelled by the crop; lock the crop in the inspector when a static frame is wanted. Hovering the timeline shows a skim thumbnail; it does not move the playhead or the main preview. Export can pick source/30/60 fps (capped by the recording), writes MP4 with fast-start, shows Dock progress, and posts a local notification if the studio is in the background. The studio canvas can use a multi-stop angled gradient or a recently chosen local wallpaper (copied into the session; never downloaded).

**Audio in the studio.** Mute silences preview and export. Mix to mono downmixes stereo on export (and on an audio-only export), matching the record-time mono option.

**Language.** A picker; changing engine or model rewrites an unsupported choice rather than failing later. On macOS 14/15, if on-device dictation is missing, the inspector points at System Settings ▸ Keyboard ▸ Dictation instead of showing a Tidy button that can never work.

**Model download.** Separate button from Tidy. Optional, cancellable, with a disk-space precheck. The studio works without it.

**Progress and cancellation.** Transcription and model download both show progress, can be cancelled, and closing the window warns if either is running.

**Teleprompter "Follow my voice".** Audio buffers from the agent → helper → word hypotheses. While a recording already has a microphone track, the prompter listens to that stream rather than opening a second `AVAudioEngine`. The prompter advances only on words that survive two consecutive hypotheses, never scrolls backwards, and highlights the current word. Follow is forward-only; after 2.5 s of silence it falls back to pace scrolling. The Pace slider stays enabled as the fallback. "Dock under the camera" pins the panel just below the hardware notch. Installing a speech model is a button the user presses — never automatic.

**Accept:** Tidy on a 10-minute narrated recording with a mic track produces a review list and never silently removes 90% of the timeline; a transcript is produced from extracted PCM on macOS 14, 15 and 26; the mic track survives a pause; `tidySpeech` tests would fail if T-C1/T-C2/T-C3 were reintroduced; `otool -L` on the agent still shows no Speech.

---

## 2. Quick Access Overlay (P1) — the signature surface

**Behavior:** after a capture, a thumbnail card slides in when **Show a card** is on in the after-capture matrix (default on). The card appears on the display where capture happened (setting: always primary). With the card off, History still receives the file, and if neither card nor save is on the capture is written to the save folder so the staging sweep cannot delete it. Cards stack (max 5 visible, older collapse behind). Re-showing the same file moves the existing card to the front rather than duplicating it. The overlay is a non-activating floating panel: it never steals focus, appears over full-screen apps, on all Spaces.

Per-card interactions:
- **Drag out** → real file promise drag (works into Slack/Mail/Finder/browsers). Dragging out removes the card (setting).
- Single click → expand a short action row: **Copy · Save · Annotate** (screenshot) or **Studio** (recording) · **Share**. Pin, OCR, Trim, GIF, Compress, and Save As stay in the context menu, keyboard shortcuts, and Overlay ▸ Card layout — not on the picture by default. Double-click → open editor (or the studio for a recording). Auto-saved cards (not staged) show a **Trash** button on hover at the opposite corner from Hide, so a near-miss on Hide cannot throw the capture away; cards showing a History item or a file Kadr did not create (automation, Open from Clipboard) never offer Trash. Save and Save As on those *copy* the file under the name the card shows, and Rotate/Flip work on a copy (docs/17 T-OUT-5, T-OUT-7). Context menu also: Rotate 90°, Flip Horizontal, Flip Vertical, Scale Retina to 1× (CleanShot §6.2 / §8.2).
- Hover shows filename, dimensions, size, the card's corner actions, and a close (×) that **hides the card without deleting**. **Card keys act only when the overlay is key** — after the user clicks a card, as with macOS's own screenshot thumbnail — and never while another app has the keyboard: ⌫ moves the capture to the Trash with an **Undo** banner ("Moved to Trash · Undo"); Esc hides; **Return** saves and closes (configurable in Overlay settings); Space Quick Looks; ⌘C copies, ⌘S saves, ⌘E annotates (trim for a recording), ⌘P pins, and ⌘W closes. Each key acts only with exactly its own modifiers, so ⌘⌫ is never a card delete. This is a deliberate departure from CleanShot's hover keys: with the stack in the corner people park the pointer in, ⌫ typed into another app deleted captures (docs/17 T-OUT-1). Swipe toward the docked edge dismisses; swipe toward the screen edge tucks the stack into a peek tab.
- Auto-dismiss timer (default off/∞; options 5/10/30 s). Hovering, dragging, or in-flight work (compress, OCR, GIF) **pauses** the timer and retries shortly after the pointer leaves; opening the editor, studio, or trim **keeps that card** until the user hides it. **Dismiss ≠ delete**: files still land per save policy; "Restore recently closed" (menu + hotkey) brings the last N back. When several cards stack, the newest shows a small accent dot (CleanShot §6.3). **Save All** and **Close all** (menu, hotkey, peek-tab ×) dismiss cards **one at a time** so the stack reflow animates instead of jumping (CleanShot §6.3 / 4.7.5). Overlay Save that cannot write to the folder keeps the card and offers Save As; quitting with a live recording also offers to save staged captures, and a failed save cancels the quit. **Compress** copies rather than replacing: a worthwhile result gets its own card (`-compressed`) and a "62% smaller · 180 KB — copied" banner; an already-small file says so instead.
- Opening a capture in the editor (or studio / trim) **retires that card** once the editor is actually on screen: the capture is now open in a window of its own, and a thumbnail of it in the corner is a second copy of something already visible. Dismiss, not delete — the file stays where the save policy put it, History has it, and Restore Recently Closed brings the card back. Other cards are left exactly as they are, and a launch that fails leaves the card alone.
- A flick of the stack toward the screen edge, or Quick Look taking over, tucks the stack into a **peek tab** (count + ×) in the same corner. Click the tab to bring the cards back; × dismisses every card. A new capture expands the stack so the new card is seen.
- Default action on capture is configurable: copy to clipboard, save to folder, both, overlay-only (file goes to history staging and is finalized on first action — keeps Desktop clean), or **ask where to save** (a save panel as soon as the capture lands; the file stays staged until the panel confirms). Overlay Save can also ask every time (General → Ask where to save from the overlay). **Save As** on a card always asks, even when silent save is on (CleanShot §6.2).

**Accept:** overlay never takes key focus from the frontmost app; drag-out delivers a correctly named file (no `Untitled` / tmp names); stacking never overlaps the Dock; VoiceOver can reach every action.

---

## 3. Annotation editor (P1 core, grows through P3)

Opens in **its own process** (see doc 04) as a normal resizable window; multiple editors may be open.

**Model:** the base image is immutable; every annotation is a vector object (type, geometry, style, z-order) in an ordered stack → unlimited undo/redo, select/move/edit any object later, lossless re-export. "Flatten" only happens at export.

**Tools (P1):**
- **Select/move** (click, marquee, ⌘-click multi-select; eight resize handles on the selection box — corners and edges, sized in view points so they stay hittable when zoomed out; a rotate handle 14 pt outside each corner, ⇧ snapping to 15°; a lone rotated annotation's frame and handles turn with it and resize in its own axes, holding the opposite side still; everything turns about the centre of its own extent — on the canvas, in hit-testing and in the export, where rotated redactions and spotlight holes are clipped to the turned rect; a lone arrow, line or length-measurement gets path handles at its terminals instead, plus a midpoint on arrows to bend the curve; counters have no resize handles — size is a tool setting; ⇧ on a corner locks aspect, ⇧-drag on a move locks to the dominant axis, ⇧ on a path end snaps to 45°; drag from empty space inside the selection's union moves it except for a lone arrow/line/measure; open-hand cursor when hovering an annotation in Select; arrow-key nudge).
- **Arrow** — straight + curved (the midpoint handle sits on the curve); filled, open, concave, dot, bar and diamond heads at the end, optionally at the start; smart default color (auto red/contrasting). An arrow bound to another annotation follows it while that target is dragged. Spotlights share one dim so two holes stay equally bright, and they sit under the other annotations.
- **Shapes** — rect, rounded rect, ellipse, line; fill/stroke/none; stroke width via the inspector slider (presets 2/4/6/10/16 are relative to a 1440 pt canvas and scale with the capture; they sit in the 1–32 pt range); fill opacity when filled.
- **Freehand pencil** with smoothing; **Highlighter** (multiply-blend stroke).
- **Text** — inline editing, 7 style presets + custom (font/size/weight/italic/underline/color/background pill). A click places a box and opens the editor; a click on existing text edits it. The box grows with the string (and with wrapping) so a second line is not clipped on the canvas or in the export.
- **Blur / Pixelate / Erase** — rectangular region; strength is measured in the capture's pixels, and the editor previews exactly the algorithm export uses; pixelate averages each block over a randomly displaced window with a slight per-block tint on a randomly phased grid (defeats de-pixelation of predictable grids); erase fills with the dominant colour of the region's border so UI chrome disappears; irreversible at export (actually re-rendered from blurred pixels, not an overlay that can be removed from the PNG — security-reviewed).
- **Counter badges** — auto-incrementing numbered circles; formats 1 / I / A / a; drag to reorder renumbers. Size (S / M / L / XL) and colour are tool-level: changing either in the inspector updates every badge, and a badge cannot be free-resized. With the tool armed, a click on an existing badge drags it rather than stacking another on top.
- **Crop** — non-destructive; aspect presets including 3:2; expand-canvas allowed (for padding). Esc reverts to the gesture baseline; ⌥ resizes from the centre; the readout shows points and pixels on Retina. Expanded padding is filled from the capture's edge colour at export, not hard-coded white.
- **Lock objects** — toolbar lock or ⇧⌘L keeps existing annotations from moving while you draw (CleanShot §8.1). Settings ▸ General can turn this on by default for new editor sessions.
- **Object shadows** — Settings ▸ General can disable drop shadows on inserted images (CleanShot §8.2 / §21).
- **Tool size** — `` ` `` / `+` (or `-`) changes the armed tool's stroke width, text size for the text tool, or badge size for counters (CleanShot §8.2).
- **Tool hand-off:** after a one-shot tool lands (arrow, shape, line, text once the in-place editor commits, blur/pixelate/erase), the pointer returns to Select so the new annotation can be moved immediately. Pencil, highlighter, and counters stay armed — a numbered badge is one of a sequence. Crop is a mode until **Done**. Picking a drawing tool from the toolbar clears the current selection.
- Style system: last-used style per tool remembered; per-tool color/size in a floating inspector; global theme colors.
- **Canvas drawing:** annotation tools apply to the whole canvas, including beautify padding around the screenshot — not only the capture itself. Coordinates stay image-relative so a crop still makes sense; the padding is just more of that plane.
- **Inspector sliders:** every numeric control is a scrub track with the label inside it and a typed value field to the right (suffixes: "45%", "12 px", "30°", "1.5×"). Clicking the track sets the value at that position; hover reveals ticks; signed ranges (tilt, pan, roll) detent on zero. Arrow keys step one displayed unit.

**P2 additions:** Spotlight (one dim with every hole punched out, drawn under the other annotations), Smart Highlighter (Vision word-boxes snap), sticker/emoji, image insert (multi-image composition; ⌘V with an image on the pasteboard inserts it), background/beautify panel (padding, none/gradient/solid/image backdrop with recents, corner radius, shadow strength and style, 3:2 and other aspect presets, auto-balance), perspective camera (the stage is the union of the capture and the projected quad; stuck edges are ignored while a camera is on), watermark visible on the canvas as well as in the export, resize/downscale export panel, rotate / flip horizontal / flip vertical of the capture (CleanShot §8.2), per-annotation rotation.

**P3 additions:** auto-redaction assistant (pre-runs OCR + patterns for emails, phone numbers, API-key shapes, credit cards; highlights candidates; one click blurs all), background removal (subject lift), measurement overlay & pixel ruler, OKLCH/APCA color picker eyedropper, `.kadr` re-editable project file (zip: base PNG + JSON command list).

**Export:** ⌘C copy flattened (with a selection, the selected annotations ride along as a second pasteboard type for Kadr's own paste); ⌘S save next to the original when **Keep the original file** is on (General ▸ Annotate), or overwrite the capture when it is off (CleanShot §7). ⌘S also writes a sibling `.kadr` (on by default) so the capture stays re-editable; History does not list that sidecar as a second capture. Rotate and flip count as unsaved work. Closing or quitting prompts Save / Don't Save / Cancel (Esc cancels); Save writes the flattened image and the project. ⌘⇧S Save As (format picker: PNG / JPEG / HEIC / `.kadr`, with a quality slider for the lossy formats; Export Size is stored in the project, and a downscaled export is tagged at its real DPI); ⌘⌥S Save Project; File ▸ Print (⌘P, tall scrolling captures paginate across sheets); drag-out from title-bar proxy (always the flattened image, never the `.kadr`, which keeps the un-redacted original; the first save of a project with redactions says so once); "Copy without annotations" alt-action. The toolbar Save button is the silent write (CleanShot's ⌥+Save). Beside it, **Move to Trash** asks for confirmation, moves the capture and its `.kadr` project to the Trash, and closes the editor; the capture's overlay card and its History copy go with it, as they do when deleting from the card.

**Accept:** 60 fps object dragging on a 5K capture; undo depth ≥ 100; blur regions unrecoverable in exported files; editor process exits fully when last window closes (RAM returns to agent baseline).

---

## 4. Pinned screenshots (P1)

Any capture (from overlay, editor, or history) can be **pinned**: a borderless always-on-top window showing the image at captured size (drag corners to scale, keeping the capture's aspect ratio; ⌥-scroll zoom; double-click = 100%).

- Opacity (⌘-scroll or the pin's Opacity menu, 20–100%; a plain scroll does nothing, so scrolling the page under a pin never fades it); **click-through mode** (⌘⌥L) making it a pure reference layer — ⌘⌥L is also a global command, Toggle Pin Click-Through, that acts on the pin under the pointer (or the newest click-through pin) and is claimed only while some pin is click-through, since a click-through pin cannot open its own menu (docs/17 T-OUT-9); arrow-key positioning; appears on all Spaces; multiple pins.
- Pin menu (right-click): copy, save, reveal, annotate, OCR, close. Hover shows Close / Copy / Save. Pins have a window shadow. "Close all pins" global command. **Pin Clipboard** (menu + hotkey) pins an image on the pasteboard, or draws plain/RTF/HTML text as a card and pins that.
- Pins persist across app restarts (P2, from history).

**Accept:** pin windows never take focus on show; click-through verified over interactive apps; 20 pins ≤ 40 MB added RSS (downsampled backing images, full-res reloaded on demand).

---

## 5. History & library (P2), search (P3)

- Every capture recorded: file reference, thumbnail, type, dimensions, app under capture, timestamps, OCR text (lazy).
- **Menu strip:** last 8 captures as thumbnails right in the status-item menu — click to re-open overlay card.
- **History window:** grid browser with type/date/sort filters, drag-out, batch select, Copy / Annotate / Pin / Export / multi-Reveal, rename for every kind, Space for Quick Look, delete (with file), storage usage meter. Retention setting: keep forever / 30 days / 7 days / session-only; size cap with LRU eviction. A change that deletes asks first with the count and size; choosing session-only asks when History is not empty, naming what the next launch will clear, and is not saved until confirmed. ⇧⌘L opens History; the menu bar also has **Open Capture Folder** and a Recent submenu.
- **P3 — search:** full-text over OCR'd content + window/app names ("that screenshot of the stripe error last week"). Fully local SQLite FTS index; indexing runs only on idle power + only for history-retained items; opt-out.

**Accept:** history browser cold-opens < 400 ms @ 1k items (thumbnails paged from disk); deleting from history removes files; index adds zero agent idle cost (indexer runs in editor/helper process, exits when done).

---

## 6. Sharing — drag-and-drop only, everything local (P1)

There is deliberately **no sharing infrastructure**: no hosting, no upload targets, no share-by-URL, no accounts. The app's sharing model is the thing macOS already does perfectly:

- **Drag-and-drop is the primary path** — from the Quick Access Overlay card, the editor's title-bar proxy icon, a pinned window, and any history item. Drags are `NSFilePromiseProvider` file promises, so the receiving app (Slack, Mail, Figma, browsers, Finder) materializes a properly named file even when the capture only exists in staging. A promise drop copies straight from staging and does not also finalize the capture into the save folder (one copy, where the user dropped it). A receiver that reads only the file URL gets the staging path, and that staged file is then exempt from the 24-hour staging sweep so the link it keeps never breaks.
- **Clipboard is the second path** — configurable default action "copy on capture"; ⌘C anywhere copies the flattened image. The clipboard item carries the native bytes plus PNG/TIFF fallbacks and, for a finalised file, a file URL so terminals and “paste a file” apps work. HEIC and WebP still paste into apps that only understand PNG.
- **Native share sheet** (`NSSharingServicePicker`) from overlay/editor/history — AirDrop, Messages, Mail, and whatever share extensions the user has installed. The OS handles delivery; the app never talks to a server.
- Consequence worth advertising: **nothing you capture ever leaves the Mac.** The app contains zero networking code, and reaches the network in exactly two places, both enforced by CI: Sparkle's update check, and — only if you ask for it — asking macOS to install a speech model so the studio can offer to cut filler words. The studio works without that model, transcription is on-device either way, and no recording is ever uploaded. Nothing to configure, nothing to trust.

---

## 7. Desktop hygiene & precision utilities (P2)

- **Hide desktop icons** (and widgets): toggle from menu/HUD/URL scheme; auto-hide while recording (setting); temporary wallpaper override (solid color/image) during capture. Icons are hidden by a window showing each display's wallpaper just above the icon layer — never by restarting the Finder — so hiding is instant, a Finder copy in progress is untouched, and nothing is left hidden if Kadr quits or crashes. The cover shows a still frame of the wallpaper, and the same one on every Space.
- **Crosshair precision mode:** full-screen crosshair guides + coordinates while selecting (toggle in overlay with `C`).
- **Screen freeze** as a standalone toggle (freeze display(s) to inspect moving UI, then capture normally) — the P1 area-capture freeze exposed as its own command.

---

## 8. App shell & UX chrome

### 8.1 Menu bar item (P1)
Template-style icon; states: idle / capture armed / recording (red + timer). An update a background check found badges the idle icon with a dot, adds **Update to X…** to the top of the island's Tools menu and to the short menu, and shows a line with **Install…** in Settings ▸ Updates. **Click = capture island** (§1.4). **Right-click, ⌃-click or ⌥-click = a short menu** — while recording too, where a plain click stops the take and these open the menu, and VoiceOver reaches it through a "Show Kadr Menu" action: the live recording's controls (only while recording), the last-captures strip, History…, Recover Unfinished Recordings (only when there are some), a **Pins & Overlays** submenu (only while cards, pins or recently closed captures exist), Finish Setup… (only while Screen Recording is not granted), Settings…, Quit. Capture modes and utilities are not listed in the menu — they live in the island. Check for Updates lives in Settings ▸ Updates. Drag a file *onto* the icon → opens in editor (P2).

**Default global shortcuts (five).** A global hotkey is taken from every app on the Mac, so only commands people fire without looking ship with one, next to or mirroring the system's ⇧⌘3/4/5: ⇧⌘2 capture island, ⌃⇧3 Capture Screen, ⌃⇧4 Capture Area, ⌃⇧6 Record…, ⌃⇧. Stop Recording. Every other command is unassigned by default and can be bound in Settings ▸ Shortcuts. On upgrade, a shortcut still equal to any earlier default moves to the current default (or is cleared); shortcuts the user recorded are kept, and a command whose new keys are already taken keeps the shortcut it had. Reopening the already-running app from Finder or the Dock opens the menu if the icon is visible, or Settings if it is hidden (and the recording bar if a take is in progress). **Show menu bar icon** in General can hide the extra. About Kadr ships MIT notices for Sparkle, KeyboardShortcuts and GRDB.

### 8.2 Onboarding (P1)
First launch: 3 screens max. (1) What it does + the main hotkeys; (2) **Permissions** — Screen Recording required; Accessibility, Input Monitoring, Microphone and Camera optional. Compact rows with live status (Allow / Open Settings / Allowed / Restricted), deep-links, live-detect on return from System Settings, resume after a grant that needs a relaunch, and an honest note about macOS 15’s monthly re-confirmation; (3) defaults choice: clipboard-first vs file-first, save folder, launch-at-login opt-in, plus a practice image that opens the editor with no capture. Total < 2 min; every screen skippable. Settings ▸ Permissions is the same recovery UI for people who skipped.

**First-run tips (native popovers, each shown once, each dismissable).** About a second after launch — or after the welcome window closes — a popover under the menu-bar icon says where Kadr lives: the island shortcut (the user's actual binding, omitted if unassigned), that a click opens the island and a right-click the menu, with **Open It Now** / **Got It** / ×. It also closes when the icon is clicked or the island opens. The first time the island opens, a three-page tour points at it: the mode letters (A W F R, Return, Esc), the other modes and the Tools letters, and the global shortcuts as currently bound with a **Shortcuts…** button; Back / Next / Done, page dots, ×. Picking a mode or closing the island ends it, and closing the tour hands the keyboard back to the island so the letters it just taught work immediately. Any close counts as seen. **Settings ▸ General ▸ Show Tips Again** and replaying the welcome re-arm these and the first-capture card tip. Nothing is built until a tip shows, and everything is released when it closes; Reduce Motion turns the popover animation off.

### 8.3 Settings (P1, grows)
Panes: General (login item, show menu bar icon, default action, save folder with middle truncation and Use Default, optional ask-where-to-save from the overlay, filename template `{app}-{date}-{time}`, format, quality for lossy formats, Retina downscale, optional convert-to-sRGB on save, capture sound), Permissions (live TCC status and recovery for Screen Recording, Accessibility, Input Monitoring, Microphone and Camera), Shortcuts (recorder UI for every command), Overlay (corner, size, timeout, stacking, optional always-show actions), Capture (cursor, shadow, snapping, auto-crop notch, fullscreen target, overlay teaching hints, OCR review window), Recording (P2), History (P2), Advanced (URL scheme/CLI install, include Kadr overlays in captures, reset). Settings window is a normal app-style window (works around LSUIElement focus quirks per doc 04).

### 8.4 Automation (P2)
- URL scheme: `kadr://capture-area?action=copy|save|annotate|pin&x=&y=&w=&h=`, `capture-window`, `capture-fullscreen`, `capture-text`, `record-screen?fps=`, `pin?filepath=`, `toggle-desktop-icons`, `open-history`, `open-settings?tab=` … (CleanShot-verb alias table for Raycast migration).
- CLI `kadr` (symlinked helper): same verbs, stdout paths/text, `--json`; exits non-zero on cancel. Relative paths resolve against the shell's directory.
- Shortcuts.app actions wrapping the same command layer.
- **Consent (docs/17 T-OUT-12).** Kadr holds the Screen Recording grant, so driving it is guarded:
  - URL scheme: **Settings ▸ Advanced ▸ Allow other apps to control Kadr**, off by default. With it on, the first request from each app asks "Allow “Raycast” to control Kadr?" and the answer is remembered per app (bundle identifier and signing team), listed in Settings with Forget. A sender Kadr cannot attribute to an app is asked every time. The sender is read from the Apple event that carried the URL. A refused request does nothing and shows "Kadr blocked a request from …" with a Settings button. Silent capture, recording and file-reading verbs never run for an app that was not allowed.
  - CLI: the agent checks the code signature of every sender on its Mach port, from the kernel's audit token; only code signed by Kadr's team (in development, code inside the Kadr bundle) is served. Others get exit code 77.
  - Shortcuts intents and Kadr's own editor are always allowed.
  - **Accept:** with the switch off, `open "kadr://capture-fullscreen?action=copy"` takes nothing and says so; with it on, the first request from an app asks once and a denial sticks; a process not signed by Kadr's team sending on the Mach port gets `denied`.

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
