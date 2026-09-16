# Screendrop Parity Plan

> Written 2026-09-15 from a code-reading review of both repositories. Nothing here
> has been built or run.
>
> Screendrop (`/Users/bohdanbodnarenko/Developer/personal/Screendrop/Screendrop/`, **SD**)
> is the reference app. This plan lists everything Screendrop does that Kadr is missing
> or does worse, in the order to fix it.
>
> The following documents stay authoritative: `03-features.md` for behaviour, `04-swift-architecture.md`
> for structure, and `CLAUDE.md` for the hard rules. `08-screendrop-analysis.md` is out of date: it says
> recording, telemetry and studio parity "has since been built". Those features exist,
> but several of the ports are partial or less reliable than Screendrop's (§4, §5, §8).
> Update doc 08 when Phase 1 lands.

## 1. How to read this

**Review scope.** Six parallel reviews compared the apps area by area:
- capture and selection;
- post-capture surfaces (cards, pins, History, clipboard);
- the screenshot editor;
- the recording flow up to Stop;
- the recording studio;
- the app shell.

Findings that showed up in more than one review are merged into the cross-cutting section (§3).
The highest-impact claims were spot-checked against the current code while writing:
- the studio keeps only the first audio track (`ClipComposition.swift:54`);
- the after-capture "Show a card" setting is never read;
- `didStopWithError` only logs (`RecordingEngine.swift:390`);
- style memory is never saved;
- there is no `applicationShouldHandleReopen` and no `beginActivity`;
- `hasUnsavedChanges` compares only commands.

**Item IDs.** `X` cross-cutting · `CAP` capture · `OUT` cards, pins and History ·
`ED` screenshot editor · `REC` recording flow · `STU` studio · `APP` app shell.

**Effort.** S ≤ 1 day · M 2–4 days · L 1–2 weeks (one engineer, including tests).

**Impact.** **Critical** means data or content loss, or a core loop broken.
**High** means a visible defect on a common path. **Med** and **Low** as usual.

**Verify** marks behaviour that can only be confirmed on a real Mac with TCC grants,
such as SCK frame semantics or cross-app hotkey conflicts. Check these first on
device; do not treat them as settled.

**Every item follows the project rules:**
- **Rule 1, zero network.** No port may bring in cloud features or CDN wallpaper packs.
- **Rule 2, agent RAM.** Anything in the agent is lazy and has no timers.
- **Rule 4, SwiftUI.** SwiftUI stays inside hosting views, and the selection overlay stays CALayer-only.
- **Rule 5, concurrency.** AsyncStream at delegate boundaries, and no new DispatchQueues except SCK handler queues.
- **Rule 6, geometry.** Coordinates go through `Shared.Geometry`.
- **Rules 7–9, spec and tests.** Update docs/03 in the same PR, add signposts on budgeted paths, and write table-driven or perf tests.
- **Screendrop's `Engine/` code.** It is a tldraw port: re-implement the behaviour, never copy the code.

---

## 2. Phased roadmap

Each phase is one branch or milestone (docs/06 convention). The phase's "Done when" list is
the union of the per-item acceptance checks in §3–§9. Items in one phase are independent
unless a dependency is listed.

### Phase 0 — Stop losing work (≈ 2 weeks)

Silent loss of footage, captures, narration or edits. Most items are S.

| ID | Item | Impact | Effort |
|---|---|---|---|
| REC-1 | Stream dies mid-recording (window closed, display unplugged, sleep): Kadr keeps "recording" into nothing | Critical | M |
| REC-2 | Writer failure (disk full) deletes the whole take at Stop | Critical | M |
| REC-3 | Start/stop/stitch failures only logged; footage folder never shown | High | S |
| STU-A1 | Studio preview and every export drop the mic track when system audio was also recorded | Critical | S |
| OUT-3 | Card Save dismisses the card even when saving failed; staging sweep deletes it | Critical | S |
| ED-7 | ⌘S bakes annotations (no `.kadr`), rotate/flip isn't "unsaved", ⌘Q never prompts | High | M |
| CAP-1 | Notch crop removes the visible menu bar from every fullscreen shot | High | S |
| REC-6 | No idle-sleep / App Nap assertion while recording | Med | S |
| REC-7 | In-progress segments live in `$TMPDIR` (purged by macOS) | Med | S |
| OUT-17 | Quitting mid-recording silently discards staged captures | Med | S |

### Phase 1 — Trust the output (≈ 4 weeks)

The canvas must match the export, and the timeline must match the footage.

| ID | Item | Impact | Effort |
|---|---|---|---|
| ED-1 | Text on canvas ≠ export; multi-line text clipped in the exported file | Critical | M |
| ED-3 | Watermark invisible on the canvas | High | S–M |
| ED-2 | Arrowheads differ canvas vs export; no start head | High | M |
| ED-5 | Bound arrows don't follow a dragged/resized target until mouse-up | High | S–M |
| ED-9 | Multiple spotlights stack their dimming; spotlights dim later arrows | Med | M |
| ED-8 | Curved-arrow middle handle is off the curve | Med | S |
| STU-A2 | Export follows SCK's variable frame rate, so zooms and cursor freeze on static screens | High | S–M |
| STU-A3 | Zoom cues stored in edited time drift after any cut, trim, speed change or Tidy Speech | High | M |
| STU-A4 | Reconstructed cursor stale after a cut | Med-High | S |
| STU-A5 | Captions squashed horizontally instead of wrapping | Med-High | M |
| STU-A6 | Padding breaks the export aspect ratio; "fit" letterboxes onto black | Med-High | M |
| REC-9 | Telemetry clock freezes on static screens, so clicks land early | High | S (partial) / L |
| REC-10 | Clicks and keys made while paused land at the cut | Med | S |
| REC-11 | Window recordings use `contentRect` as an on-screen rect (**verify**) | High | M |
| REC-4 | Audio shares a 3-deep drop-oldest buffer with video | Med-High | M |

### Phase 2 — Daily-loop quick wins (≈ 2–3 weeks)

Mostly S items that users hit on every capture.

| ID | Item | Impact | Effort |
|---|---|---|---|
| X-1 | Clipboard is single-format: HEIC/WebP paste fails; no file URL | High | M |
| OUT-1 | After-capture "Show a card" never read; recording Copy/Save ignored | High | M |
| X-2 | Hotkey conflicts and registration failures silent; no Restore Default | High | M |
| APP-1 | Relaunching the running app does nothing visible | High | S |
| ED-6 | Style memory resets for every capture | High | S |
| X-3 | No capture sound | Med | S |
| X-4 | OCR not in reading order; empty OCR reports success | Med | S |
| X-5 | Cards, pins, bar, camera, prompter and HUD placed on `NSScreen.main` | Med | S |
| REC-16 | Opening the record picker activates Kadr (recorded app loses focus) | Med | S |
| CAP-8 | All-in-One HUD makes Kadr the "frontmost app" for the capture (**verify**) | Med | S |
| OUT-4 | Editor saves never update the card, History or clipboard | Med-High | M |
| APP-3 | No ⌘W / ⌘M / real Window menu in agent windows | Med | S |
| APP-4 | Re-showing an open Settings/History/Help window doesn't bring it forward | Med | S |
| OUT-7 | Pins stretch when resized | Med | S |
| OUT-11 | History arrow keys assume a 560 pt wide window | Med | S |
| OUT-14 | Re-showing a capture creates a duplicate card | Low-Med | S |
| OUT-15 | Last card and peek tab vanish without an exit animation | Low-Med | S |
| APP-10 | No `Credits.rtf`: MIT notices for Sparkle, KeyboardShortcuts and GRDB not shipped (compliance) | Med | S |
| REC-17 | Transport buttons live while pausing/stopping (double-tap becomes Pause→Pause) | Low | S |
| REC-20 | Window pick swallows permission errors | Low | S |

### Phase 3 — Motion and performance (≈ 4–5 weeks)

| ID | Item | Impact | Effort |
|---|---|---|---|
| STU-B3 | Frame composer rebuilds full-canvas bitmaps and caption cues every frame | High | S–M |
| STU-B1 | First-order "spring": zooms jerk at start; the "Move" slider does nothing | High | M |
| STU-B2 | Cursor reconstruction: no click anticipation or drag tracking; clicks teleport | High | M |
| STU-B4 | Preview decodes each frame at full resolution through `AVAssetImageGenerator` at 30 Hz | High | L |
| STU-B5 | Filmstrip re-decodes the whole strip on every zoom step; ruler not culled | Med-High | M |
| STU-B6 | Motion blur weighted unevenly, fixed sample count | Low-Med | S |
| ED-4 | Perspective or progressive blur hides drags, handles, drafts and crop | High | L |
| ED-15 | Redaction previews re-blurred on every click; handles rebuilt every drag frame | Med | S–M |
| ED-11 | Freehand not smoothed (raw polyline), despite docs/03 | Med | S |
| OUT-19 | History thumbnails decode synchronously on main; no sort or list | Low-Med | M |
| REC-5 | Stop after a pause pays a full passthrough export; audio lost after resuming on a static screen | Med | M |
| REC-18 | Camera sync offset measured at queue time; camera pauses and stops late | Med | M |

### Phase 4 — Feature depth (≈ 6–8 weeks, can be split)

**Studio:**

| ID | Item | Impact | Effort |
|---|---|---|---|
| STU-C1 | Follow-camera for 9:16, 1:1 and 4:5 (today, vertical exports lose all zooms) | High | L |
| STU-C3 | Tidy Speech refuses after any trim; cuts clip into words | Med | S–M |
| STU-C4 | Captions and transcript can't be corrected | Med | M |
| STU-C2 | Smart anchor mode; auto-zoom ignores single clicks | Med | M |
| STU-C5 | Hover-skim preview on the timeline | Med | S |
| STU-C6 | Export fps choice, MP4 fast-start, dock progress, completion notification | Low-Med | S |
| STU-C7 | Wallpaper recents and multi-stop angled gradients in the studio | Low | S–M |
| STU-C8 | Named undo; zoom drags clamp against neighbours | Low | S |
| STU-C9 | Recent recordings, last-opened ordering, styled posters | Low | S–M |

**Screenshot editor:**

| ID | Item | Impact | Effort |
|---|---|---|---|
| ED-16 | Wallpaper backdrop picker, shadow strength and style, blur focus and tilt-shift, safe preset import, default look for new captures, camera stage padding | Med | M each |
| ED-13 | Stroke and badge sizes scale with the capture size | Med | M |
| ED-12 | ⇧ axis lock, drag inside hollow selection, hover cursors, click-to-place default size | Med | S |
| ED-10 | Per-annotation rotation | Med | L |
| ED-14 | Smart redaction: URL and IPv4 detectors | Low-Med | S |
| ED-17 | Crop cancel and ⌥ from centre, cascading paste, paste image, text Esc semantics | Low | S |

**Capture, post-capture and shell:**

| ID | Item | Impact | Effort |
|---|---|---|---|
| CAP-3 | Fullscreen target: active display, all displays, or stitched; clipboard gets the active display | Med | M |
| OUT-5 | Compress: progress, result, and a card for the compressed file | Med | M |
| OUT-6 | Drag adds a `.fileURL` flavour next to the file promise | Med | S–M |
| OUT-8 | Pin hover controls, shadow, and a real "Save…" | Med | M |
| OUT-9 | Quick Look in History (Space) | Med | S |
| OUT-10 | History Copy/Annotate/Pin/Export/multi-Reveal/rename for screenshots | Med | M |
| APP-2 | "Show menu bar icon" option | Med | S–M |
| APP-7 | `FailurePresenter` for `kadr://`, login item, relaunch and CLI uninstall | Med | S–M |
| APP-8 | App Intents: Toggle Recording, more AppShortcuts, `openAppWhenRun` | Low-Med | S |
| X-6 | Opt-in: include Kadr overlays in captures and screen sharing | Low | S |
| X-7 | Menu bar: Open Capture Folder, keyboard-reachable Recent submenu, History key equivalent | Low-Med | S–M |
| CAP-9 | Quality slider for JPEG/HEIC/WebP | Low | S |
| OUT-16 | Auto-dismiss waits for in-flight work | Low | S |
| OUT-20 | Save panel can change format | Low | S |
| APP-6 | Shortcuts list sectioned (with X-2) | Low | S |
| APP-11 | Settings window: `isMovableByWindowBackground = false`, animation behaviour | Low | S |
| APP-13 | Save folder row: middle truncation, help, Use Default | Low | S |

**Recording:**

| ID | Item | Impact | Effort |
|---|---|---|---|
| REC-14 | Validate devices and permissions at start; no silent camera fallback | Med | M |
| REC-8 | Crash recovery uses the telemetry journal and a real manifest | Med | M |
| REC-12 | Keystroke and mouse coverage: F-keys, repeats, other buttons, drag | Low-Med | M |
| REC-19 | Teleprompter: forward-only follow, pause, display link, recording mic, word highlight, follow toggle | Low-Med | S–M each |
| REC-13 | Re-enable a timed-out event tap | Low | S |

**Polish:** APP-P1…P5 (§9.2).

**Rough total:** 18–23 engineer-weeks. Phases 0–2 (≈ 8 weeks) close every Critical and High item except the studio motion and preview work.

---

## 3. Cross-cutting items

These showed up in two or more reviews; implement each one once.

### X-1 Clipboard writes one format only — High, M
*(capture review #2, post-capture review #2)*

- **Screendrop:** `ScreendropPreferences.swift:303-342` (`ScreenshotFileActions.copyImageToClipboard`) writes one
  `NSPasteboardItem` with three flavours: the file URL, native PNG/JPEG data, and TIFF. Its comment explains why: terminals and "paste a file" apps read the URL, while
  Gmail and Notes read pixels.
- **Kadr:**
  - Where it writes:
    - `CaptureOutput.copyToClipboard` (`CaptureOutput.swift:282-295`) writes only the export's own type.
    - `QuickAccessManager.copyFile` (`QuickAccessManager.swift:374-385`) writes raw bytes under the file's UTType.
  - Why that fails: HEIC is used automatically for HDR captures and is the default compression format, and WebP is offered. For those, the clipboard holds only `public.heic` or `org.webmproject.webp`, which browsers, Slack, Discord and Figma can't paste.
  - There is no file URL, so pasting into terminals or CLI agents fails.
- **Plan:**
  1. MediaExport: add a pure `PasteboardFlavorPlan.for(format:isFinalized:) -> [Flavor]`
     (native, pngFallback, tiffFallback, fileURL). Table-tested.
  2. Agent: add `Kadr/QuickAccess/ClipboardWriter.swift` (@MainActor).
     - Write the native bytes eagerly.
     - Register PNG and TIFF through `NSPasteboardItemDataProvider`, so the decode only happens if
       a receiver asks. This keeps rule 2 and the selection→clipboard budget.
     - Add `.fileURL` **only for finalised files**. Capture-time auto-copy points at a staged path
       that later moves, so leave the URL off there.
     - Keep the provider alive until `changeCount` changes.
  3. Replace both call sites. History Copy (OUT-10) and pin Copy use the same writer.
  4. Tests: write to a uniquely named pasteboard and assert the flavour set for each format.
- **Risks:**
  - A lazy TIFF of a 5K image is a transient ~60 MB decode at paste time; measure it with the
    existing clipboard signpost.
  - Some apps prefer the URL and paste an attachment. Keep image data first, and order it the other way only if Mail misbehaves.

### X-2 Hotkey conflicts, registration failures and reset — High, M
*(capture review #4; app shell #5, #6)*

- **Screendrop:**
  - Refuses a shortcut that another action already uses, and names that action
    (`CaptureHotkeySettingsSection.swift:104-122`).
  - Registers the new key before releasing the old one, and reports a `RegisterEventHotKey` failure ("may be used by another app",
    `HotkeyManager.swift:86-114`).
  - Lists errors on each row, with a Reset button per row.
- **Kadr:**
  - Validation: `HotkeyCenter.validate` (`HotkeyCenter.swift:110-117`) only rejects Option-only shortcuts, and KeyboardShortcuts 3.0.1 doesn't check other shortcuts within the same app. One key on two commands fires both.
  - Registration: `HotKey.swift:261-279` and `onRegistrationFailed` swallow failures, so ⌃⇧A held by CleanShot or Raycast silently never fires.
  - Reset: rows have no Restore Default. "Reset All Settings" (`AppSettings+Reset.swift`) skips shortcuts, even though `AdvancedPane.swift:49-57` promises "every preference".
  - Layout: the 22 rows are one flat list.
- **Plan:**
  1. `HotkeyCenter.validator(for: CaptureCommand)`: the pure part checks the shortcut against every other
     command through an injected lookup, then `.disallow("Already used by \(other.shortcutTitle)")`.
     Table-driven KadrTests.
  2. `Kadr/Hotkeys/HotkeyHealth.swift` (`@MainActor @Observable`): probe each shortcut with Carbon
     `RegisterEventHotKey` + `UnregisterEventHotKey` under a separate signature.
     - When: at `HotkeyCenter.start()` (before registration) and on KeyboardShortcuts' change notification. Event-driven, zero timers.
     - Skip the probe when the shortcut equals the row's current value, or it would report Kadr's own registration.
  3. `ShortcutsPane`:
     - Row layout: an inline `ControlInlineStatus` under a failing recorder, plus "Restore Default"
       (`KeyboardShortcuts.reset`, disabled when already the default).
     - List-wide: a "Restore All Shortcuts" footer, a warning glyph on the sidebar row, and sections from
       `CaptureCommand.menuCommands/utilityCommands/overlayCommands/recordingCommands`.
  4. Wire the shortcut reset into `AdvancedPane`'s Reset All in the app target, so SettingsKit stays
     free of KeyboardShortcuts.
- **Verify:** whether Carbon reports other-process conflicts on macOS 15/26.

### X-3 Capture sound — Med, S
*(capture review #5, app shell #9)*

- **Screendrop:** `CaptureCoordinator.swift:199-233` plays `…/SystemSounds/system/Screen Capture.aif` through a lazily
  created `NSSound`. It stops and rewinds before each play, and beeps when OCR finds nothing. The General pane has a toggle.
- **Kadr:** no `NSSound` anywhere. A capture that only copies, or is triggered by automation, gives no confirmation at all.
- **Plan:**
  - Add `Kadr/UX/CaptureSound.swift` (@MainActor). The sound loads on first play, never at launch, and falls back to
    `NSSound(named: "Grab")` or skips.
  - Add SettingsKit key `general.playsCaptureSound` (default on) and a GeneralPane toggle.
  - Call sites:
    - `AreaCaptureCoordinator+Delivery.deliver` and `deliverAll` (once per action);
    - scroll-capture finish;
    - OCR success, and a beep on empty (X-4).
  - Skip it when automation passes a silent override.
- **Spec:** docs/03 §1.3 says fullscreen is "silent (no overlay)". Read that as "no UI" and write the reading down.
  Consider honouring the system "Play user interface sound effects" setting.

### X-4 OCR reading order and empty results — Med, S
*(capture #6/#7, post-capture #13, app shell #8)*

- **Screendrop:**
  - `ImageTextRecognizer.swift:44-82` groups observations into visual lines (vertical centres
    within half a box height), then orders each line left to right. It uses an explicit grouping pass, because a tolerance comparator is not a strict weak ordering.
  - Empty results show "No text found", beep, and make the Shortcuts intent throw.
- **Kadr:**
  - Order: `VisionServices/TextRecognizer.swift:99-110` keeps Vision's order, and
    `Shared/VisionInterface.swift:118-121` just joins the lines.
  - Empty results:
    - The toast reads "Text copied, 0 characters" (`TextCaptureToast.swift:145-150`) while its body says "No text found".
    - `.text("")` is reported as success (`AreaCaptureCoordinator.swift:482`), so `CaptureTextIntent` (`KadrAppIntents.swift:84-86`) and the CLI succeed with empty text.
    - An empty review window can open.
- **Plan:**
  1. Add `Shared/Geometry/ReadingOrder.swift`: `visualLines(_:) -> [[RecognizedLine]]`, a strict half-height overlap grouping. Join words within a line with a space, or with a tab when the gap is more than about 2× the median character width. Apply it in `VisionAnalysis.text(preservingLineBreaks:)`, and skip it when a `RecognizedTable` is primary.
     - Table tests: split fragments, skew, a two-column form, an empty list. Don't claim column detection.
  2. Branch on `recognition.isEmpty` in `recognizeText` and `recognizeFile`:
     - UI: title "No text found", a matching VoiceOver announcement, no review window, and the X-3 beep.
     - Automation: add a distinct `noText` status in AutomationKit that maps to a non-zero CLI exit, and `KadrIntentError.noText`.
       Document both in `docs/AUTOMATION.md` (this changes the CLI contract). Add parser and transport tests.

### X-5 Multi-display placement uses `NSScreen.main` — Med, S
*(capture #8, post-capture #12, recording #21)*

- **Screendrop:** `ActiveDisplayResolver.swift:30-108` picks the frontmost window's screen, then the pointer's
  screen, then main. It is used for cards, the recording bar and the camera.
- **Kadr:** `NSScreen.main` is used in:
  - `QuickAccessManager.targetScreen()` (`:337-347`) when `displayID` is nil, which is the case for recordings, scrolling captures, History reopens and clipboard files;
  - `PinManager.pin` (`:55`);
  - `AllInOneHUD` (`:85`);
  - `RecordingControlBar` (`:357-366`);
  - `CameraPreviewPanel` (`:136-157`);
  - `TeleprompterPanel` (`:98`).
- **Plan:**
  - Add a single `Kadr/UX/ActiveScreen.swift` helper that resolves in this order: explicit display ID, then the screen containing
    `NSEvent.mouseLocation` (through a `Shared.Geometry` `ScreenPoint`, rule 6), then main.
  - Thread the recorded display ID into `showRecording(at:displayID:)`, `RecordingControlBar`, the camera preview and the prompter. Pins open on the card panel's screen.
  - Remember one saved bar position per display.
  - Unit-test the resolution order with injected screens.

### X-6 Opt-in to include Kadr overlays in captures — Low, S
*(capture #10, app shell #14)*

- **Screendrop:** "Include Screendrop windows in captures" (`PreviewWindowCaptureExclusion.swift:17-58`).
- **Kadr:** `NonActivatingPanel.swift:59` hard-sets `sharingType = .none`. Kadr's per-window registry is
  better; only the opt-in is missing.
- **Plan:**
  - OverlayKit: a static `CaptureVisibility.includesOverlays`, set by the agent (OverlayKit can't import
    SettingsKit). `CaptureExclusionRegistry.refresh()` re-applies `sharingType`.
  - The selection overlay, countdown and scroll HUD always stay `.none`. The macOS 15.2+ direct rect path
    relies on that.
  - Toggle in `AdvancedPane`, default off.

### X-7 Menu bar entry points — Low-Med, S–M
*(capture #11, post-capture #18, app shell #12)*

- **Screendrop:**
  - "Open Screenshots Folder": creates the folder if needed, alerts on failure.
  - A "Recordings" submenu with a "– Unsaved" marker.
  - "Recent Captures" as standard menu items.
  - "Open Library" ⇧⌘L.
- **Kadr (`StatusItemController.swift:270-308`):**
  - There is no folder item.
  - History has no key equivalent and no `CaptureCommand`.
  - The thumbnail strip is a custom-view menu item, so arrow keys skip it.
  - Recording thumbnails open a card instead of the studio, which is inconsistent with History's double-click.
- **Plan:**
  1. Add `CaptureCommand.openSaveFolder` and `.openHistory`, wired into `HotkeyCenter`, the status menu and `AppMenu`.
     The folder item creates the folder when missing and reports failure through APP-7.
  2. Add a lazily built "Recent" submenu of standard items from `history.recent`, with 16 pt thumbnails from the strip cache, purged in
     `menuDidClose`. Keep the strip for pointer users.
  3. Strip and Recent recording items call `openFromHistory`, which opens the studio when a session exists. Mark studio drafts with a dot, read
     lazily when the menu opens (rule 2: no scan at launch).
- **Spec:** docs/03 §8.1 lists the menu contents, so note the additions.

---

## 4. Capture and selection (CAP)

Kadr is far ahead here. Screendrop takes stills with `/usr/sbin/screencapture` and has no loupe,
snapping, scrolling capture, freeze or HUD. The gaps are correctness details around the capture itself.

### CAP-1 Notch crop removes the visible menu bar — High, S (Phase 0)

- **Screendrop:** `NotchBarTrimmer.swift:29-112` trims only a strip that is actually empty black:
  - it counts channels above 14 and bails once non-black pixels pass 0.2%;
  - when it does trim, it removes 2 extra rows to catch a leftover hairline.
- **Kadr:**
  - `CaptureCore/NotchCrop.swift:14-58` crops whenever the capture covers the top of the display and the inset is above 0, without looking at any pixels.
  - `FullscreenNotchCropper` runs it on every `deliver` and `deliverAll`, including `F` on the overlay, ⌘A and freeze.
  - `cropNotchFromFullscreen` defaults on, so on a notched MacBook **every fullscreen still loses its menu bar**. That contradicts docs/03 §1.3 ("fullscreen stills of an app that covers the display").
- **Plan:**
  1. `NotchCrop.stripIsEmpty(_ image:, rows:, channelThreshold: 14, maxNonBlack: 0.002) -> Bool`:
     draw only the strip into an 8-bit RGBA buffer and exit early once the limit is passed. Pure.
  2. Gate `apply` on it, and trim `topPixels + 2` (clamped).
  3. Table tests in `NotchCropTests`:
     - black strip → cropped;
     - menu text → kept;
     - near-black noise → cropped;
     - strip taller than half the image → kept.
  4. Add a signpost (the fullscreen budget). Change the copy in `CapturePane.swift:82-88` to "Trim the empty notch strip".

### CAP-3 Fullscreen target and multi-display clipboard — Med, M (Phase 4)

- **Screendrop:** captures only the active display (`CaptureCoordinator.swift:85-95`), producing one file and one card.
- **Kadr:**
  - `AppDelegate+Commands.swift:57-58` and the HUD always call `captureAllDisplays()`.
  - Captures are sorted by display ID, and `deliverOffMain` copies index 0 to the clipboard. That is the lowest display ID, not "the one they were looking at".
  - docs/03 §1.3's "one file per display, or stitched — setting" and HUD display choice are not implemented.
- **Plan:**
  1. Add SettingsKit `FullscreenTarget { activeDisplay, allDisplays, allDisplaysStitched }`, defaulting to `allDisplays`, and a picker in `CapturePane`.
  2. Route `AreaCaptureCoordinator+Direct` through X-5's resolver. For "all", put the active display first so the clipboard gets it.
  3. Stitched mode: add a pure `MediaExport/DisplayStitcher.swift`.
     - Layout: by global point rects, at the highest scale factor, with transparent gaps.
     - Table tests: mixed DPI and negative origins.
     - Memory: two 5K displays decode to about 120 MB, so encode and release immediately and never keep it in the agent.
  4. HUD: with more than one screen, the Screen button becomes a display menu.

### CAP-8 All-in-One HUD steals "frontmost app" — Med, S, verify (Phase 2)

- **Kadr:**
  - `AllInOneHUD.swift:50,67` calls `NSApp.activate(ignoringOtherApps:)`.
  - `beginOverlayCapture` then samples `frontmostAtHotkey`, and `SelectionOverlayController.present` stores `previouslyActiveApp`. Both likely resolve to Kadr.
  - As a result, `{app}` filenames and History metadata say "Kadr", and focus returns to Kadr afterwards.
- **Plan:**
  - Capture `NSWorkspace.shared.frontmostApplication` *before* activating, and thread it through `performAllInOne`
    into `beginOverlayCapture(…, frontmost:)` and `present(previouslyActive:)`.
  - Ignore Kadr's own bundle ID in `currentFrontmostApp()`.
  - Place the HUD on the pointer's screen (X-5).

### CAP-9 Quality slider for lossy formats — Low, S (Phase 4)

- **Kadr:** `ImageEncoder.swift:24` hard-codes 0.9.
- **Plan:**
  - Add SettingsKit `general.lossyQuality` (0.1–1, default 0.9) with a clamp test.
  - GeneralPane shows a slider when the format is not PNG.
  - Pass the value through `CaptureOutput.encodingOptions` and the editor's MediaExport calls.

### CAP-11 Low items (Phase 4)

- **Shadows on macOS 14.0–15.1.**
  - Set `ignoreShadowsDisplay = false` explicitly in freeze and display/region captures.
  - Add a docs/12 manual row: overlapping windows on a light wallpaper, macOS 14. **Verify.**
- **Self-timer for Capture Text.** Optional; docs/03 §1.5 doesn't list it.

---

## 5. Post-capture: cards, pins, History (OUT)

`docs/08` is out of date here too: stack hit-testing, the peek tab, the engagement rule, the matrix,
card layout and compression are all ported.

### OUT-1 "Show a card" never read; recordings ignore Copy, Save and Ask — High, M (Phase 2)

- **Screendrop:** `ScreenshotPreviewStack.add(url:)` / `addVideo(url:)` check `.showOverlay`. With it off, Screendrop still
  saves and runs copy, annotate and pin.
- **Kadr:**
  - Nothing reads `AfterCaptureActions.overlay`; confirmed by grep. `QuickAccessManager.show` and
    `showRecording` always put up a card.
  - For recordings, only `.openEditor` is read (`AppDelegate.swift:155`).
  - Recordings always write to `settings.saveFolder`, so the recording row's `.save` and `.promptSave` do nothing.
  - `CaptureOutput.policy` reads only the screenshot row.
- **Plan:**
  1. `AreaCaptureCoordinator+Delivery`: when `.overlay` is off, skip `quickAccess.show`, but call a new
     `QuickAccessManager.ingestWithoutCard(_:capture:)` so History keeps the capture. Then run the other actions.
  2. `CaptureOutput.policy`: with no card *and* no save, nothing finalises the staged file. Force `savesToFolder`
     in that case, and document it.
  3. Recording `onFinished`: read the `.recording` row. `.overlay` decides between showing a card and ingesting only; `.copy` calls
     `copyFile(isVideo: true)` through X-1; `.promptSave` calls the card's `promptSave`.
  4. Stop offering `.save` for recordings in `AfterCaptureActions.applies(to:)`, because they always save.
  5. Tests: matrix tests in SettingsKit, and an agent test that no card appears when `.overlay` is off.
- **Spec:** docs/03 §2 says "after every capture, a thumbnail card", while docs/09 U2.2 defines the matrix. Resolve this in docs/03.

### OUT-3 Card Save dismisses on failure — Critical, S (Phase 0)

- **Screendrop:** `save(id:)` (`ScreenshotPreviewStack.swift:541-619`) keeps the card and offers Choose Another Location, Retry or
  Cancel.
- **Kadr:**
  - `QuickAccessManager+Save.save` (`:10-17`) calls `finalizeIfStaged` and then always dismisses.
  - `finalizeIfStaged` returns silently when `finalizeStaged` gives nil (missing, full or unwritable folder).
  - The card vanishes, and the 24 h sweep deletes the staged file.
  - `saveAll()` and the quit prompt's "Save All" have the same problem.
- **Plan:**
  - `finalizeIfStaged` returns `Bool`. When it fails:
    - card Save: show `presentFeedback(.failure("Couldn't save to <folder>", retryTitle: "Save As…"))`, keep the card and `noteEngagement`;
    - `dismissCardsSequentially(finalizeBeforeDismiss:)` keeps the cards that failed and reports how many;
    - `applicationShouldTerminate` cancels the quit if fewer were saved than attempted.
  - Test with an unwritable save folder.

### OUT-4 Editor saves never reach the card or History — Med-High, M (Phase 2)

- **Screendrop:** `applyAnnotation(originalURL:historyURL:)` (`:626-668`) swaps the card's URL and thumbnail in place, replaces
  the export and re-copies. `ScreenshotHistoryStore.commitAnnotations` updates the History row.
- **Kadr:**
  - The editor overwrites the capture or writes a sibling, and sends nothing to the agent. After annotating:
    - the card thumbnail and pixel size are stale;
    - History still holds the content-addressed pre-edit bytes, so the History window and the strip show and drag the unannotated image;
    - in keep-original mode, the annotated file gets no card and no History row;
    - the clipboard still holds the old image.
- **Plan:**
  1. Add `Shared/CaptureSavedNotice.swift`, mirroring `CaptureDeletionNotice`. It carries the original path, saved path and the
     pre-overwrite hash, and validates that both files exist and that the saved file is in the original's folder or the save folder.
     The editor posts it at the end of `save(_:)`.
  2. Add `Kadr/QuickAccess/QuickAccessManager+EditorSaves.swift`, a distributed-notification observer (no timer). It:
     - finds the card and sets `fileURL`, `pixelSize` and `contentRevision += 1`;
     - `history.ingest`s the saved file, and deletes the old library bytes only when the file was overwritten in place;
     - re-copies when the matrix `.copy` is on.
  3. Tests: notice encode/decode and path validation, as in `CaptureDeletionNoticeTests`.
- **Pairs with ED-7a:** the sibling `.kadr` must not create a second History row.

### OUT-5 Compress feedback and result card — Med, M (Phase 4)

- **Screendrop:** a spinner overlay, a new compressed card placed next to the source, and a "JPG ready ↓42% · 180 KB" badge.
- **Kadr:**
  - There is no in-progress state, and `compressionSavings` is never displayed.
  - The output sits in `temporaryDirectory` and only reaches the clipboard, as HEIC (see X-1).
  - When compression isn't worthwhile, nothing is shown.
- **Plan:**
  - Add `QuickAccessItem.activity: CardActivity?` (`.compressing`, `.recognizingText`, `.exportingGIF`), shown as a small progress capsule with no layout change.
  - Feedback: `.completion("HEIC · 62% smaller · 180 KB — copied")` on success, `.warning("Already as small as it gets")` otherwise.
  - Write the result into `StagingArea` as `<stem>-compressed.<ext>` and `present(_:after:)` a card for it, ingested like a normal capture.
- **Spec:** docs/09 U2.4 says "copies rather than replaces". The extra card is additive; note it.

### OUT-6 Drag adds a file-URL flavour — Med, S–M (Phase 4)

- **Kadr:** `FilePromiseDragController` offers only `NSFilePromiseProvider`. Terminal, iTerm, many Electron/Chromium drop zones
  and some IDEs receive nothing.
- **Plan:**
  - Subclass `KadrFilePromiseProvider`: `writableTypes(for:)` adds `.fileURL`, and `pasteboardPropertyList(forType:)`
    resolves lazily (finalises staged files).
  - History: resolve to a temporary hard link named with `originalFilename`, because library files are named by hash.
  - Add a manual matrix to the PR: Finder, Mail, Slack, Chrome upload, Terminal, VS Code.

### OUT-7 Pins stretch — Med, S (Phase 2)

- **Plan:**
  - `PinPanel.init`: set `contentAspectRatio` to the image size, `minSize` to 80 pt proportional, and `.scaleProportionallyUpOrDown`.
  - Test: a skewed `setFrame` keeps the ratio.

### OUT-8 Pin hover controls, shadow, real Save — Med, M (Phase 4)

- **Screendrop:** a hover toolbar with Close, Copy and Save; Copy shows a checkmark for 1.5 s; Save opens an `NSSavePanel`; the window has a shadow.
- **Kadr:**
  - There are no visible controls.
  - `configureAsOverlay` sets `hasShadow = false`.
  - "Save…" actually runs `revealInFinder` (`QuickAccessManager+Actions.swift:192,241`).
- **Plan:**
  - Add an AppKit-only `Kadr/Pins/PinHoverBar.swift`: a tracking area and an `NSVisualEffectView` holding Close, Copy and More. Hide it in click-through mode.
  - Copy shows a checkmark via a one-shot `Task.sleep`.
  - Set `hasShadow = true` after `configureAsOverlay`.
  - Add `QuickAccessManager.saveCopy(of:)` using `NSSavePanel.begin` (copy, don't move), and make "Reveal in Finder" a separate item.
- **Spec:** docs/03 §4 mentions only the context menu; the hover bar is additive.

### OUT-9 Quick Look in History — Med, S (Phase 4)

- **Plan:**
  - Make `QuickLookPresenter` multi-item (an array plus `currentPreviewItemIndex`) and give `HistoryController` its own instance.
  - Space toggles Quick Look for the selection and follows selection changes. "Open in Overlay" stays in the context menu, with ⌥Return as its shortcut.

### OUT-10 History actions — Med, M (Phase 4)

- **Kadr today:**
  - The only actions are Open in Studio, Rename (studio sessions only), Open in Overlay, Reveal, Share and Delete.
  - `revealSelected` acts on only the first selected item.
- **Plan:** add to `HistoryController`:
  - `copy(ids:)`: through X-1 for one item, temporary hard links for several;
  - `export(ids:to:)`: off-main, using `CaptureFileWriter.availableURL`;
  - `reveal(ids:)` for multiple items;
  - `annotate`, `pin` and `copyText`, through closures as `reopen` already does.
- **In `HistoryView`:** ⌘C via `.onCopyCommand`, a toolbar Actions menu, and rename for every record kind.

### OUT-11 History arrow keys — Med, S (Phase 2)

- **Plan:**
  - Measure the grid width with `onGeometryChange` and pass the real column count to `moveFocus`.
  - Add the widths 400, 720 and 1000 to the `HistoryGridMetrics` table tests.

### OUT-14 / OUT-15 / OUT-16 Card lifecycle (S each)

- **OUT-14, duplicates.** `present` moves an existing card for the same file to the front, restacks, reschedules auto-dismiss and returns.
- **OUT-15, exit animation.**
  - Add an observed `isExiting` flag. When the last card goes, the stack or peek tab slides out, then a one-shot 340 ms `Task.sleep` runs before `teardownOverlay`.
  - `present` cancels a pending exit. With Reduce Motion, tear down immediately.
- **OUT-16, auto-dismiss.** `isIdleForAutoDismiss` also requires `activity == nil` (OUT-5).
- **Also: momentum swipe.** Ignore events with `momentumPhase != []` in `OverlaySwipe` (pass the phase through
  `QuickAccessOverlayPanel.scrollWheel`), so one flick can't dismiss the next card too. Neither app does this today.

### OUT-17 Quit mid-recording drops staged captures — Med, S (Phase 0)

- **Kadr:** the recording branch of `applicationShouldTerminate` (`AppDelegate.swift:384-407`) returns before the
  unsaved-cards check.
- **Plan:**
  - Compute the unsaved count first, and add "Save N captures too" to the recording alert (a relabelled suppression button).
  - Call `finalizeAllStaged()` before `finishForTermination`, respecting OUT-3's failure result.

### OUT-19 History browsing and thumbnails — Low-Med, M (Phase 3)

- **Plan:**
  - Sorting: `HistorySort` in `HistoryFilter`, a toolbar sort menu, and a second caption line (relative date · app · size).
  - Thumbnails: an async `.task(id:)` per cell, a synchronous `ThumbnailCache.cached(for:)` fast path, and the decode in a detached task.
  - Keep the docs/03 §5 "<400 ms @ 1k" check as a test.

### OUT-20 Save panel format — Low, S (Phase 4)

- **Plan:**
  - Allow PNG, JPEG, HEIC and WebP, with an accessory format popup. When the extension changes, re-encode off-main.
  - Replace `runModal` with `begin`.

---

## 6. Screenshot editor (ED)

### ED-1 Text on canvas ≠ export; text clipped — Critical, M (Phase 1)

- **Screendrop:**
  - One layout engine (`Engine/TextMeasure.swift`) serves the canvas and the export.
  - Text boxes auto-size: the width grows, the height always equals the measured text, and the alignment anchor stays fixed while typing.
  - A side handle sets a wrap width; a corner handle scales the font.
- **Kadr:**
  - Canvas: `AnnotationLayerFactory.textLayer` (`:273-293`) is a `CATextLayer`. It ignores `isBold` and alignment, and draws a fixed-radius pill with no padding.
  - Export: `AnnotationExportRenderer.drawText` (`:342-370`) uses `TextLayout` (bold face, alignment, padded pill, `CTFramesetter`). **The two differ.**
  - `TextSpec.rect` is set once (200×40 on click) and `updateText` changes only `string`, so a second line is **clipped on the canvas and in the exported PNG**. Hit-testing also uses the stale rect.
- **Plan:**
  1. AnnotationRender: add `TextRendering.draw(spec, in:)` and `frame(spec)` on top of `TextLayout`. The export calls them.
  2. Replace the `CATextLayer` with a `TextBadgeLayer: CALayer` whose `draw(in:)` calls the same code, following the `CounterBadgeLayer` pattern.
  3. AnnotationModel: `TextSpec.autoWidth` (`decodeIfPresent`; default `true` for new text, `false` for legacy files).
  4. `updateText`: inside the open gesture, set `rect.size` from `TextLayout.measuredSize` on every keystroke, and keep the alignment anchor fixed.
     `SelectionResizer.scaledText` side handles set `autoWidth = false`.
  5. Optional: `isItalic` and `isUnderline` in `TextStyle` (`decodeIfPresent`, and preset equality must still hold).
  6. Tests: a golden test that the canvas layer draw equals the export crop for bold, centred and pill text; a model test that multi-line text grows its rect.

### ED-2 Arrowheads canvas ≠ export; more heads — High, M (Phase 1)

- **Kadr:**
  - Canvas: `arrowPath` (`:142-166`) strokes the head polyline with the shaft's width and a round join, then fills it.
    - A `.filled` head is blunter and larger than the export's fill-only triangle.
    - `.concave` has no notch on the canvas.
    - The shaft pokes through the tip on thick arrows.
  - Model: end head only, 3 styles, fixed length `max(3.5w, 12)`.
- **Screendrop:** 8 head types at start and end; length `clamp(len/5, w, 3w)`.
- **Plan:**
  1. AnnotationRender: add `ArrowGeometry` returning `(shaft, head, headIsFilled)` for start and end.
     - Trim the shaft by the head inset.
     - Head length `clamp(chord/5, 1.5w, 4w)`, plus a minimum.
  2. Canvas: an `ArrowLayer` (shaft plus a head sublayer). The export fills and strokes the same paths.
  3. AnnotationModel: `ArrowSpec.startHead: ArrowHead?` (`decodeIfPresent`), plus new `.dot`, `.bar` and `.diamond` styles, clean-room.
  4. Inspector: start and end head pickers.
  5. Tests: canvas and export paths are equal; a head-length table.
- **Spec:** docs/03 says "3 head styles"; update it.

### ED-3 Watermark invisible while editing — High, S–M (Phase 1)

- **Kadr:** only the export and the camera/blur offscreen render draw `document.watermark`.
- **Plan:**
  - Add `watermarkLayer` in `AnnotationCanvasView` (inside `drawingHost`, above annotations), rasterised once with
    `WatermarkCompositor.draw`. Don't use thousands of text layers: the tile cap is 4000.
  - Add the watermark to the layout key, and hide the layer while the offscreen render shows.
  - Also draw the watermark **after** the scene progressive blur in `AnnotationExportRenderer+Canvas.swift:103-107`.
  - Golden test: canvas placement equals export placement.

### ED-4 Perspective and blur make editing blind — High, L (Phase 3)

- **Kadr:** `showOffscreenLayer()` (`+Chrome.swift:147-165`) hides the annotation, draft, selection and crop layers, and
  refreshes only on mouse-down or mouse-up. While a camera or any blur is on, drags and handles are invisible.
- **Screendrop:** keeps the live foreground under `.projectionEffect`, sets the camera to identity while cropping or editing text,
  and shows the exact render only when idle.
- **Plan:**
  1. Add a pure `Homography.caTransform3D` in AnnotationModel, with a table test that its corner mapping matches `project`. Apply it to `drawingHost`, and
     show the offscreen render only as an idle overlay (no drag, no selection).
  2. Clipped blur: blur only `baseLayer` live at display resolution, with annotation layers on top.
  3. Scene blur: show the offscreen render only when idle.
  4. With `tool == .crop` or text editing active, treat the camera as identity: skip both unprojection and the offscreen render.
- **Risk:** `CATransform3D` signs under a flipped view (why the current code avoided it). The corner test guards this.

### ED-5 Bound arrows lag their target — High, S–M (Phase 1)

- **Kadr:** `rebuildAnnotationLayersDuringMove` (`AnnotationCanvasView.swift:338-353`) updates only selected ids, so an
  arrow bound to the dragged shape jumps on mouse-up. Arrows aimed at a counter hit its bounding square, not its circle.
- **Plan:**
  1. At gesture start, precompute `dependents: [AnnotationID: [AnnotationID]]` next to `dragStartCommands`, and update
     the selected layers plus their dependents each frame.
  2. While drafting or dragging a terminal, compute `binding(at:)` for the live end and draw an accent hint outline in `selectionLayer`.
  3. Add a circle case for `.counter` in `ArrowBindingResolver.endpoint` (reuse `ellipseCrossing`).
  4. Test: `layersNeedingUpdate(duringMoveOf:)` includes the dependents.

### ED-6 Style memory not persisted — High, S (Phase 2)

- **Kadr:** `EditorDocumentModel.styleMemory = StyleMemory()` (`EditorDocumentModel.swift:36`) is never saved or loaded, so every
  capture starts at red, 4 pt, filled head. docs/03 §3 promises "last-used style per tool remembered".
- **Plan:**
  - Add `StyleMemoryStore` in EditorUI, backed by UserDefaults like `EditorUserPalette` (not SettingsKit).
  - `load()` in `init`; a debounced `save()` from `rememberStyle` and every `apply*` setter. Optionally remember the last tool too.
  - Tests: round-trip, and decoding an older blob.

### ED-7 Save and close lifecycle — High, M (Phase 0)

- **Screendrop:**
  - Every save writes both the composite and an editable sidecar.
  - Dirty state covers base, shapes, bindings and background.
  - A Save / Discard / Cancel sheet, and `isDocumentEdited` is mirrored.
- **Kadr gaps and plan:**
  - **(a) ⌘S loses re-editability.** `save(_:)` writes only the flattened image. With "Keep original" off, it overwrites the capture.
    - Also write a sibling `.kadr` without revealing it in Finder, embedding the original base PNG.
    - Controlled by an editor preference, default on.
    - Update docs/03 §3, and make sure History doesn't list both files (OUT-4).
  - **(b) Rotate/flip isn't dirty.** `hasUnsavedChanges` is `document.commands != savedCommands`.
    - Also store and compare `savedOrientation`.
    - Autosave observes `document.orientation`.
    - Test: rotating makes `hasUnsavedChanges` true.
  - **(c) ⌘Q never prompts.** `EditorAppDelegate.applicationShouldTerminate` (`:161-183`) checks only studio exports.
    - Collect dirty editor controllers and review them in turn, or write autosave synchronously and quit (recovery covers it).
    - Edits made less than 1.5 s before quitting must be flushed.
  - **(d) Close sheet.** Split `writeProject` into write and reveal, so the close path doesn't pop Finder.
    - Buttons: "Save" (flattened + project), "Don't Save", "Cancel"; Esc cancels.
  - **(e) No dirty dot.** Set `window.isDocumentEdited = model.hasUnsavedChanges` from the autosave observation loop.

### ED-8 Curved-arrow handle off the curve — Med, S (Phase 1)

- **Kadr:** `SelectionResizer.applyPath(.pathMiddle)` stores the pointer as the quadratic control point, so the apex sits
  halfway between the chord and the pointer.
- **Plan (AnnotationModel only):**
  - When dragging, set `control = 2·handle − (start+end)/2`, and draw the handle at `B(0.5) = (start + 2·control + end)/4`.
  - Keep the 4 pt snap-straight rule on the apex distance.
  - Stored files stay compatible. Table test the apex/control round-trip.

### ED-9 Spotlights stack — Med, M (Phase 1)

- **Screendrop:** draws one dim layer with every hole punched out, after redactions and before the other shapes.
- **Kadr:** each spotlight dims the whole canvas with only its own hole (`AnnotationLayerFactory+Spotlight.swift:29-47`,
  `AnnotationExportRenderer.drawSpotlight` `:197-214`). It also follows z-order, so it dims arrows drawn earlier.
- **Plan:**
  1. AnnotationModel: add `SpotlightComposite`: one dim opacity (the maximum) plus the list of hole paths.
  2. Export: one even-odd dim after base and redactions; skip `.spotlight` in `drawContent`.
  3. Canvas: one `spotlightLayer` under `annotationLayer` with a multi-hole mask; the per-command layer becomes an invisible hit proxy.
  4. Test: two spotlights give equal brightness in both holes.
- **Spec:** spotlights always sit under annotations; add a note to docs/03.

### ED-10 Per-annotation rotation — Med, L (Phase 4)

- **Plan:**
  - Model: `rotation` (`decodeIfPresent`, 0) on Shape, Text, Redaction, Spotlight, Image and Freehand specs.
    - Hit-test by inverse-rotating the point; the bounding box becomes the rotated AABB.
    - `SelectionResizer` resizes in local space and gains a `.rotate` handle 14 pt outside each corner; ⇧ snaps to 15°.
  - Render: a layer transform around the centre on the canvas, and `context.rotate` on export.
  - Redaction: rasterise the AABB and clip to the rotated rect. Stays burned in.
  - Arrow bindings: resolve against the rotated outline.
- **Spec:** new behaviour, so it needs a docs/03 entry.

### ED-11 Freehand smoothing — Med, S (Phase 3)

- **Kadr:** `FreehandSpec.isSmoothed` says smoothing happens at render time, but both renderers draw the raw polyline.
- **Plan:**
  - Add a pure `StrokeSmoothing` in AnnotationModel: RDP simplification at about 0.5 pt, plus centripetal Catmull–Rom → cubic Béziers. Table-tested.
  - Use it for both the layer and the export. `updatePath` drops points within 0.5 pt of the last one.
  - Later (M): a pressure-based variable-width outline. perfect-freehand is MIT, so it could be ported with attribution after a docs/04 §12 justification.

### ED-12 Selection interaction details — Med, S (Phase 4)

- **Plan:**
  - ⇧-drag locks to the dominant axis.
  - A drag from empty space inside the selection's union bounds moves the selection (except a lone arrow, line or measure).
  - Cursors: open hand when hovering an annotation in Select (via `mouseMoved` → `refreshCursor`), closed hand while moving.
  - Optional: click-without-drag with shape, redaction or spotlight places a default box of `max(48 pt, 8%)` of the image. Note it in the spec.

### ED-13 Styles scale with the capture — Med, M (Phase 4)

- **Plan:**
  - Add `StyleScale.factor(for canvasSize:) = clamp(longestEdgePt / 1440, 0.75, 3)`, table-tested.
  - Apply it when creating drafts, counters and text, without changing remembered style memory. Show the effective value in the inspector.
- **Spec:** docs/03's 2/4/6/10/16 presets become relative to a 1440 pt canvas.

### ED-14 URL and IPv4 smart-redaction detectors — Low-Med, S (Phase 4)

- **Plan:**
  - Add `SecretKind.url` and `.ipAddress` in `Shared/SecretScanner.swift`.
    - IPv4 is validated per octet.
    - URLs are limited to `scheme://…` or `www.…`, never bare domains.
    - Both rank below credentials and JWTs.
  - Add table tests.

### ED-15 Editor performance — Med, S–M (Phase 3)

- **Kadr:**
  - Every mouse-down and mouse-up rebuilds all layers, which re-blurs every redaction with no cache.
  - The 9 handle layers are recreated on every drag frame.
- **Plan:**
  - Add a bounded (~32 MB) preview cache in `AnnotationLayerFactory`, keyed by the rect (integral), style and image identity, and cleared when the base changes.
  - Mouse-down syncs layers in place unless the document changed.
  - Reposition handle layers instead of recreating them.
  - Add a signpost around the rebuild, and a perf test that a rebuild with 20 redactions stays under N ms.
- **Verify:** stitched captures over 16384 px can exceed the GPU texture limit. If so, show a downsampled or tiled preview; export stays full resolution.

### ED-16 Beautify, camera, blur and preset gaps — Med (Phase 4)

- **Wallpaper backdrop picker (M).**
  - Add an Images row with recents and a "+" tile, a `BackdropRecents` store, `WallpaperCache` thumbnails and de-duplicated copies.
  - Today "Choose Image…" only shows when the backdrop is already `.image`.
- **Shadow (S).** Add a strength slider and a style control (soft, long, glow, crisp). `BeautifyShadow` already has the parameters.
- **Progressive blur (M).** Add a focus pad for `ProgressiveBlurSpec.center` and a symmetric tilt-shift band.
- **Preset import (M).**
  - Add `StylePreset.sanitized()` to clamp every metric, since a hostile `padding` could allocate a huge bitmap.
  - Add a format key and reject unknown versions.
  - Give duplicate names unique suffixes instead of replacing, and report errors instead of `try?`.
  - Allow importing more than one file.
- **Default look for new captures (M).**
  - "Use for New Captures" writes `StylePreset` JSON to App Support.
  - The agent applies it through `CaptureProject`, using AnnotationModel only (rule 2).
- **Camera without beautify (M).** Make the stage the union of the content and `CameraQuad` bounds, and ignore stuck edges under a camera.
- **Also (S):**
  - add `BeautifyBackdrop.none` for a border alone;
  - move the wallpaper decode off main with an in-flight de-dupe;
  - add a 3:2 aspect;
  - round the card shadow corners under a camera.

### ED-17 Minor (S, Phase 4)

- **Crop:** Esc cancels (reverts to the gesture baseline), ⌥ resizes from the centre, and the readout shows pixels as well as points on Retina.
- **Paste:**
  - Repeated pastes cascade their offset instead of stacking at +16.
  - ⌘V with an image on the pasteboard goes to `insertImageFromClipboard`.
- **Text:** `TextOverlayEditor` Esc — either implement abandon or fix the comment.
- **Beyond parity:** snapping and alignment guides against other annotations and the capture's `edgeCandidates`.

---

## 7. Recording flow up to Stop (REC)

### REC-1 Stream death ignored — Critical, M (Phase 0)

- **Screendrop:** the stream error → `handleCaptureError` path finalises, keeps the footage and says "Everything captured so far was saved"
  (`ScreenRecordingManager.swift:211-215, 472-487`).
- **Kadr:**
  - `StreamOutput.stream(_:didStopWithError:)` (`RecordingEngine.swift:390-393`) logs and finishes the continuation.
  - The engine stays `.recording`, and the coordinator is never told.
  - The wall-clock bar timer keeps counting.
- **Plan:**
  1. RecordingCore: add `public enum RecordingEngineEvent { case streamStopped(String), writerFailed(String) }` and
     `nonisolated var events: AsyncStream<RecordingEngineEvent>` (rule 5). `StreamOutput` yields `.streamStopped`.
  2. `RecordingCoordinator.start` consumes `events` while recording. On an event it calls `stop()` with an
     `interruptionReason`, so the footage is saved and the card appears, with a notice (REC-3).
  3. Test through `primeForTesting` plus a fake delegate call.
- **Spec:** docs/03 §1.8 doesn't cover this; write the behaviour down.

### REC-2 Writer failure deletes the take — Critical, M (Phase 0)

- **Kadr:**
  - `SegmentWriter.append` quietly returns false once the writer's status stops being `.writing` (`:138`).
  - `finishWriting` returns nil when the status is `.failed` (`:203-206`).
  - `stop` then throws `noFramesCaptured` and `cleanUp()` deletes the session directory, including playable 2 s fragments.
- **Plan:**
  1. On the first `.failed`: store the failure and yield `.writerFailed` (REC-1).
  2. `finishWriting` on `.failed` returns the URL if the session started and the file exists. Playability is judged later
     (`VideoPosterFrame.duration > 0.1`).
  3. Add `RecordingResult.interruption: String?`.
  4. Optional: at start, warn when `volumeAvailableCapacityForImportantUsage` is low.
  5. Test with a fake `SegmentWriting` that fails mid-take.

### REC-3 Failures invisible — High, S (Phase 0)

- **Kadr:**
  - Only permission errors reach the user.
  - `targetUnavailable`, writer creation errors and stop failures are log-only.
  - `RecordingError.stitchFailed` carries the folder that holds the footage, but nothing displays it.
- **Plan:**
  - Add `Kadr/Recording/RecordingFailureNotice.swift`. `stitchFailed` shows an alert with "Show in Finder".
  - Start failures are shown too, except `cancelledDuringStart`.
  - After stop, use an `NSAlert`. During a recording, use a transient line in the bar, never a modal.
  - Reuse APP-7's presenter for anything non-modal.

### REC-4 Audio shares a 3-deep drop-oldest buffer — Med-High, M (Phase 1)

- **Kadr:**
  - Video, system audio and mic all flow through one `AsyncStream(.bufferingNewest(3))` (`RecordingEngine.swift:360-362`).
  - A consumer stall longer than 20–30 ms drops the oldest buffers, often audio. That threatens docs/03 §1.8's "A/V drift < 1 frame over 10 min".
- **Plan:**
  - Use two continuations: video keeps `.bufferingNewest(3)` (the IOSurface cap, docs/07 H6); audio gets `.bufferingOldest(256)`.
  - Two consumer tasks. Optionally a second SCK handler queue for audio (allowed by rule 5).
  - Count drops with a signpost.
  - Test: 50 audio and 10 video boxes into a slow consumer lose no audio.

### REC-5 Pause via segment close and stitch — Med, M (Phase 3)

- **Kadr:**
  - Stop after any pause runs a full passthrough export before the card appears.
  - A new segment starts only on the first *complete* video frame, so after resuming on a static screen, narration is lost until something changes.
- **Plan:** keep the last pixel buffer in the engine.
  - `beginSegment` appends it at the resume time, which starts the session so audio is kept.
  - `stop` appends it at the real end time, so a static tail survives.
  - The card shows "Finishing…" while the stitch runs.
- **Alternative (L):** a single fragmented writer with retimed timestamps. Needs a docs/04 §4.3 decision entry and a reworded docs/03 criterion.

### REC-6 No activity assertion — Med, S (Phase 0)

- **Plan:**
  - Hold `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled])` from a successful start until stop, cancel, restart or failure.
  - Put it behind a small protocol for tests.
  - It exists only while recording, so rule 2 holds.

### REC-7 Segments in `$TMPDIR` — Med, S (Phase 0)

- **Plan:**
  - Inject `segmentRoot: URL` into `RecordingEngine.init`; the app passes `Application Support/Kadr/InProgress`.
  - `InterruptedRecordingStore` and `RecordingCrashRecovery` scan both locations for one release.

### REC-8 Crash recovery ignores data it has — Med, M (Phase 4)

- **Kadr:**
  - `RecordingCrashRecovery.writeManifest` hard-codes `hasBakedCursor: true`, 60 fps and the `NSScreen.main` scale.
  - `input.jsonl` is never read.
  - `adopt` pairs footage with `.first`, which is wrong when there are two interrupted takes.
- **Plan:**
  - Write a provisional manifest at `StudioSessionRecorder.start`, and a `session.link` file in the segment folder.
  - Recovery pairs by that link and converts the `TelemetryJournal` into `input.json`.
  - Journal the cursor artwork too, with a versioned format.

### REC-9 Telemetry clock freezes on static screens — High (Phase 1)

- **Kadr:**
  - Events are stamped with the time of the last complete composited frame.
  - With the studio cursor (`showsCursor=false`), moving the pointer changes no pixels, so the clock stops.
  - `TelemetryPolicy.shouldRecord` then rejects samples, and clicks land seconds early.
- **Partial fix (S, do first, verify):** `StreamOutput` forwards `.idle` frames as clock-only boxes.
- **Full fix (L):**
  1. A pure `RecordingTimeline` of `(hostStart, hostEnd, recordingOffset)` with `recordingTime(forHost:) -> TimeInterval?`
     (nil inside pauses). Table-tested.
  2. The engine publishes segment anchors from sample host timestamps.
  3. `PointerTelemetryRecorder` stores host times and converts them at flush and stop.
  4. Version the journal format.

### REC-10 Input during pause is recorded — Med, S (Phase 1)

- **Plan:**
  - `PointerTelemetryRecorder.pause()` and `resume()` put an `isPaused` guard on pointer, click and keystroke.
  - The coordinator calls them synchronously on the button press, before awaiting the engine.
  - Test via `recordClickForTesting`. REC-9's full fix subsumes this.

### REC-11 Window recordings misuse `contentRect` — High, M, verify (Phase 1)

- **Kadr:**
  - `RecordingEngine.swift:404-415` reads `.contentRect` as a screen rect; its own DEBUG comment says this is unverified.
  - `WindowGeometryTracker` and the dim hole depend on it.
  - The window scale comes from `CGMainDisplayID()`.
- **Screendrop:** `.screenRect` for on-screen bounds, `.contentRect` for placement inside the surface, and per-frame `.scaleFactor`.
- **Plan:**
  - Carry `screenRect`, `contentRect` and `scaleFactor` in `SampleBufferBox`, and pass all three to the geometry observer.
  - Map in two steps in `WindowSpace.framePoint`. The highlight uses `screenRect`; the manifest scale comes from the first frame.
  - Rebuild the `WindowSpaceTests` fixtures from a real probe log.

### REC-12 Keystroke and button coverage — Low-Med, M (Phase 4)

- **Plan:**
  - Extend `TelemetryPolicy.SpecialKey` with F1–F19, fn and Caps Lock, plus an `isRepeat` input (pure, table-tested).
  - Add a local monitor next to the global one, and `.otherMouse*` to the tap mask.
  - `PointerSample.isDragging` (`decodeIfPresent`).
  - Request listen access from the record island through `CaptureAccessPrompt`, never mid-recording.

### REC-13 Timed-out tap — Low, S (Phase 4)

- **Plan:**
  - Re-enable the tap up to a budget (3 times in 60 s) before dropping to monitors.
  - Move the `NSCursor` lookup out of the tap callback and onto the clock tick.

### REC-14 Devices and permissions at start — Med, M (Phase 4)

- **Kadr:**
  - A stale mic ID goes straight to SCK.
  - The camera silently falls back to the default device (for example, a Continuity iPhone).
  - Camera failures are log-only.
  - GIF and automation starts bypass the permission gate.
  - Pre-roll toggles skip permission checks.
- **Plan:**
  - Add `Kadr/Recording/RecordingInputResolver.swift`, called before `engine.start`.
    - It validates IDs against `RecordingDeviceCatalog` (add `microphone(withID:)`) and reads authorization without prompting.
    - Downgrades show as a transient bar line, not a modal.
  - Pre-roll toggles go through `RecordSetupModel`'s access flow.

### REC-16 Picker activates Kadr — Med, S (Phase 2)

- **Kadr:** `RecordingControlBar.present(key: true)` calls `NSApp.activate` (`:287-290`), so the app to be recorded goes inactive.
- **Plan:** remove the call. `NonActivatingPanel` can already become key.
- **Verify:** Esc and the `CaptureAccessPrompt` popover still work in a panel that is key but not activated.

### REC-17 Transport while settling — Low, S (Phase 2)

- **Plan:**
  - Add `RecordingControls.isTransitioning`, set by the coordinator around start, pause, resume and stop.
  - The buttons are disabled while it is set.

### REC-18 Camera sync and ordering — Med, M (Phase 3)

- **Plan:**
  - Offset: compute it from the engine's first-frame host timestamp (REC-9) and the camera's `sessionStart`, both on the host clock.
  - Pause: pause and resume the camera synchronously on the button press.
  - Stop: hide the preview immediately and finish the camera concurrently with `engine.stop`.

### REC-19 Teleprompter — Low-Med (Phase 4)

- **a. Forward-only follow (S).** While following, `position = max(position, eased)`. Fall back to pace scrolling only after N seconds with no hypothesis.
- **b. Pause (S).** Stop feeding the helper while paused.
- **c. Display link (S, verify).** `DisplayLinkDriver.start` uses `NSApp.keyWindow ?? windows.first`; pass `panel.contentView` instead.
- **d. Recording mic (M).**
  - Add a mic-buffer `AsyncStream` from `RecordingEngine`, converted to 16 kHz in the app.
  - Use `AVAudioEngine` only when the recording has no mic.
- **e. Word highlight and camera placement (M).**
  - Emphasise the current word with CoreText runs.
  - Add a "Dock under camera" placement using `RecordingNotchScreen`.
- **f. Follow-voice setup (S–M).**
  - The composer gets a follow toggle and an "Install speech model…" button.
  - **Never auto-download** (rule 1: `SpeechModelInstaller` is user-initiated).

### REC-20 `pickWindow` swallows permission errors — Low, S (Phase 2)

- **Plan:** mirror `pickRegion`'s `recovery.allowCapture` check and `presentPermissionRecoveryIfNeeded`.

---

## 8. Recording studio (STU)

The studio has almost no spec in docs/03 beyond §1.9. A3, B1, B2, C1 and C3 change documented
behaviour (docs/09 U3.2/U3.3/U3.5, docs/13 T-M1). Write the new rules into docs/03 in the same PRs.

### STU-A1 Mic track dropped — Critical, S (Phase 0)

- **Kadr:** `SegmentWriter` writes system audio first and the mic second.
  - `ClipCompositionBuilder` takes `loadTracks(.audio).first` (`ClipComposition.swift:54`, confirmed).
  - `StudioRenderer` reads `.first` through one track output (`StudioRenderer.swift:281`).
  - Result: preview, audio export and every video export lose the narration.
- **Plan:**
  1. `ClipCompositionBuilder.composition`: one composition track per source audio track, each inserted and time-scaled per
     clip, in the original order.
  2. `StudioRenderer+Write.makeReader`: `AVAssetReaderAudioMixOutput(audioTracks: all)` with PCM settings.
  3. Send `StudioAudioExporter`'s M4A path through the mix too.
  4. Fixture test with two audio tracks: both carry energy in the output; the pause-stitched file survives.

### STU-A2 Export follows VFR source — High, S–M (Phase 1)

- **Screendrop:** a fixed output clock (`RecordingStudioExporter.swift:381-476`). Each tick takes the newest source frame at or
  before it, and a stale frame never carries across a clip boundary.
- **Kadr:** `StudioRenderer.write` renders one output frame per source sample. SCK writes only changed frames, so zooms,
  pans, cursor glides and ripples over a static screen never render.
- **Plan (`StudioRenderer+Write.swift`):**
  - Loop `for frame in 0..<Int((duration*fps).rounded())`.
  - Pull source and camera samples while `pts <= t`, keeping the latest.
  - Reset the held frame when the clip id changes. `pts = CMTime(value: frame, timescale: fps)`.
  - Audio drains against `pts`; progress is `frame/frameCount`.
  - Test: a VFR fixture with a 2 s gap yields `fps × duration` frames with moving viewport rects.
  - Keep the `studio.render` signpost. B3 matters more once every frame is composed.

### STU-A3 Zoom cues in edited time — High, M (Phase 1)

- **Screendrop:** cues are stored in source time and resolved through `clipTimeline.sourceTime(at:)`.
- **Kadr:**
  - `ZoomCue.start` is edited time (`ZoomCue.swift:53-55`).
  - Split, trim, remove, speed and Tidy Speech all change `clips` without touching `zooms`, so every later zoom slides.
- **Plan:**
  1. StudioSession: `StudioEdit.currentVersion = 2` stores cues in source time. v1 is migrated in `init(from:)` through the stored clips. Round-trip v1 fixtures.
  2. `ClipTimeline`: add `slices(overlappingSource:)` and `editedRange(forSource:)`.
  3. StudioRender `ViewportTimeline`: look up cues at `clips.sourceTime(forEdited:)` while stepping in edited time.
  4. EditorUI: the zoom lane draws merged edited-time blocks. `moveZoom`, `setZoomRange` and `addZoom` convert to source time.
  5. Table tests: a zoom stays on the same source frame after split, trim start, ×2 speed and middle removal.
- **Doc:** docs/09 U3.3 says "cues in edited time"; update it.

### STU-A4 Stale cursor after a cut — Med-High, S (Phase 1)

- **Plan:**
  - `InputTelemetry+Rebasing`: after mapping, seed each clip start with the last source sample at or before
    `clip.sourceStart` (binary search), carrying its cursor index.
  - Map events with a half-open range `[sourceStart, sourceEnd)`. Today `Clip.swift:161` uses a closed range.
  - Test: move during a cut, then idle; the cursor at the next clip start equals the source position.

### STU-A5 Captions squashed — Med-High, M (Phase 1)

- **Kadr:**
  - `CaptionCanvas` draws a single `CTLine`.
  - `OverlayPlacement.frame` clamps only the width.
  - `StudioFrameComposer.composite` scales X and Y independently.
  - Cue grouping has no character cap and no break on silence.
- **Plan:**
  - `CaptionCanvas(maxWidth:)` lays text out with `CTFramesetter`: at most 2–3 centred lines, font shrinks only as a fallback, karaoke colouring kept.
  - The composer passes `card.width − 2·margin` and scales uniformly.
  - `CaptionExport.cues`: at most ~42 characters, at most 4 s, and a break on gaps over 0.9 s. SRT/VTT boundaries change; note it.
  - Golden tests at 9:16 and 16:9.

### STU-A6 Aspect ratio broken by padding — Med-High, M (Phase 1)

- **Kadr:** `StudioCanvas.layout(cardSize:)` grows the canvas by the padding, so 9:16 becomes 0.587. "Show everything"
  letterboxes onto black inside the card.
- **Plan:**
  - `StudioCanvas.layout(canvasSize:contentAspect:)` keeps the canvas at the reframe output. The card is scaled by
    `1 − 2·padding/shortest`, aspect-preserved and centred. `.fit` shrinks the card instead of letterboxing.
  - `StudioRenderPlan.outputSize = evenSize(reframe output)`.
  - Table tests: exact aspect for every `ReframeAspect` × padding value.
- **Spec:** state the rule in docs/03.

### STU-B1 Real damped spring — High, M (Phase 3)

- **Screendrop:**
  - Motion: a second-order spring (tension 200, friction 40, inertia 2.25, ζ≈0.94) that integrates the half-extent.
  - Framing: comfort widening on long pans, and a 150 ms guard that keeps the pressed point inside the viewport.
  - Cues: priority pinned > smart > pointer > implicit.
- **Kadr:**
  - `MotionSpring.settled` is exponential decay with no velocity, even though its doc comment calls it "critically damped".
  - Magnification and centre are integrated independently.
  - `transitionDuration` only lengthens the zoomed span, so the inspector "Move" slider doesn't change the move.
- **Plan:**
  - Replace `MotionSpring` with `DampedSpring {position, velocity}`. Presets map to constants; derive ω ≈ 4/Ts from
    `transitionDuration` so the slider is honest, or remove the slider.
  - `ViewportTimeline`: normalised half-extent plus anchor springs, comfort widening, the 150 ms press guard, and a per-step clamp.
  - Tests:
    - no velocity jump at cue start;
    - settling time within ±15% of `transitionDuration`;
    - the press point stays inside the viewport for 150 ms;
    - preview and export frame hashes match.
  - Keep a plan-build signpost.

### STU-B2 Cursor reconstruction — High, M (Phase 3)

- **Plan (reuse B1's spring):**
  - Frame table: precompute position, press scale and cursor index per step.
  - Anticipation and drags:
    - within 0.5 s before a press, target the press point, with a stiffer intercept spring for the last 175 ms;
    - drag intervals (down/up plus movement) use a stiff tracking spring;
    - press scale follows the real hold.
  - Optional:
    - velocity tilt (a `StudioEdit` toggle, off by default);
    - a spike filter as a pure function next to `TelemetryPolicy`.
  - Ripples stay pixel-exact at `ClickEvent.position`.
  - Tests: under 2 px from the press point at press time on a fast approach; under 3 px following error during a drag.
- **Doc:** docs/09 U3.2's "snapped back at press" wording changes.

### STU-B3 Composer caching — High, S–M (Phase 3)

- **Kadr:** `StudioFrameComposer.frame(at:)` rebuilds the full-size card mask, card shadow and bubble shadow bitmaps
  (about 33 MB each at 4K) on every frame. It also rebuilds every caption cue from the transcript each frame.
- **Plan:**
  - Build an immutable `ComposerAssets` once in `init`: card mask, baked card shadow, backdrop `CIImage`, and bubble
    mask, stroke and shadow.
  - Precompute `[CaptionCue]` once per plan, binary-search per frame, and memoise the last caption image by `(cueID, activeIndex, spokenCount)`.
    Memoise keystroke pills too.
  - Perf test: 4K Presenter fps above a threshold (PRD budget: 1080p60 export at most 2× realtime).

### STU-B4 Preview pipeline — High, L (Phase 3)

- **Kadr:**
  - A 33 ms tick drives `.task(id: playhead)` → `AVAssetImageGenerator` (±100 ms tolerance) → composer → `CGImage` → SwiftUI `Image`.
  - The preview plan has no `maxLongestEdge`.
  - Audio runs on a separate `AVPlayer` that only resyncs past 120 ms.
- **Plan (EditorUI; StudioRender stays the single composer):**
  1. Playback uses one `AVPlayer` over the full composition, pulled through `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` and
     driven by `NSView.displayLink(target:selector:)`. No new queues.
  2. Compose with a preview plan at the view's pixel size and render into a `CAMetalLayer` via NSViewRepresentable.
  3. Keep the zero-tolerance generator for paused and scrub frames.
  4. Take camera frames from a second video output on the same item.
  5. Add a `studio.preview.frame` signpost; tear the output down on close.

### STU-B5 Timeline filmstrip and ruler — Med-High, M (Phase 3)

- **Kadr:** each clip's `.task(id:)` includes `Int(width)`, so every zoom step decodes the entire clip's frames. There are hundreds of lanes
  after Tidy Speech, and the ruler is a `ForEach` of `Text` across the full width.
- **Plan:**
  - Add a `StudioThumbnailStore`: `(level, index)` tile keys, visible-only requests, fallback to the parent tile, an LRU cap, and frozen tiles during pinch.
  - Replace the lanes with one AppKit lane that draws `dirtyRect`.
  - Draw the ruler as a `Canvas` over the visible span; cull click ticks and cue blocks.
  - Add a signpost on thumbnail decode.

### STU-B6 Motion blur weights — Low-Med, S (Phase 3)

- **Plan:**
  - Sample count: 1–16 from the viewport's pixel displacement across the shutter, scaled by intensity.
  - Accumulation: equal weights (additive on colour-matrix-scaled images, or source-over with alpha 1/(i+1)).
  - Unit-test that the weights are equal.

### STU-C1 Reframe follow-camera — High, L (Phase 4)

- **Kadr:**
  - `Reframe.sourceRect` is a static crop.
  - `renderableZooms` divides magnification by the crop's inherent zoom (about 3.16 from 16:9 to 9:16), so **every zoom disappears in vertical exports**.
- **Plan:**
  - Add a pure, precomputed `ReframeCamera`:
    - it follows the smoothed pointer with a dead zone of 28% of the crop and a low-pass of τ=0.45 s;
    - it hands over to the zoom anchor as magnification ramps up, and clamps to the content.
  - `StudioRenderPlan.sourceRect(at:)` composes reframe and zoom.
  - `Reframe.follows` (v2 key) keeps the static crop available as a locked mode.
  - Tests: a pointer at x=0.1 is inside the crop within 1 s; magnification is preserved; the crop stays within the source.

### STU-C2 Smart anchor and single-click zooms — Med, M (Phase 4)

- **Plan:**
  - `ZoomCuePlanner` options: `minimumClicks` (default 1) and `mergeGap` (2.5 s); cues run from −0.3 s to +2.5 s and exclude the last 1 s.
  - `ZoomAnchor.smart`: activity regions per cue, with hand-off 300 ms before each group's first click.
  - EditorUI adds "Smart" to `StudioZoomFocus`.
  - Table tests. Depends on A3/A4.

### STU-C3 Tidy Speech after edits — Med, S–M (Phase 4)

- **Plan:**
  - `ClipTimeline.removingSourceRanges([ClosedRange])`: merges ranges and keeps the leading clip's id.
  - `TranscriptCutPlanner` changes:
    - pad word and filler cuts by `min(0.12 s, gap/2)`;
    - `applying(_:to timeline:)` subtracts from the current timeline;
    - apply the 40% cap to `editedDuration`.
  - Remove the refusals in `StudioDocumentModel+Speech.swift:77-80, 186-189`.
- **Docs:** update docs/13 T-M1, docs/03 §1.9 and the tests.

### STU-C4 Transcript and caption corrections — Med, M (Phase 4)

- **Plan:**
  - Store corrections in `StudioEdit.transcriptCorrections: [wordID: text]`, so they get undo and the render stamp.
  - Timings are redistributed across the new tokens by character share.
  - Double-click to edit inline in `StudioTranscriptPanel`, through `StudioDocumentModel.editTranscript`.

### STU-C5 Hover skim — Med, S (Phase 4, after B4/B5)

- **Plan:**
  - Add `hoverPreviewTime`. While paused, the preview shows `hoverPreviewTime ?? playhead`, using a lower-resolution plan.
  - Throttle through `.task(id:)` cancellation.

### STU-C6 Export options — Low-Med, S (Phase 4)

- **Frame rate:** `StudioExportSettings.frameRate` (source/30/60), applied as `min(requested, manifest)`.
- **MP4 fast start:** `shouldOptimizeForNetworkUse = true` for MP4. It is a file-layout flag and makes no network calls.
- **Progress:** an `NSDockTile.contentView` progress bar, drawn locally without the DockProgress dependency.
- **Completion:** a local `UNUserNotificationCenter` notification when the window isn't key.

### STU-C7 Backgrounds — Low, S–M (Phase 4)

- **Plan:**
  - `StudioBackdrop.gradient(stops, angle)` with v2 decoding.
  - Reuse the editor's wallpaper recents and a few bundled images (ED-16), with no CDN. Copy the chosen file into the session.

### STU-C8 Undo names and zoom clamping — Low, S (Phase 4)

- **Plan:**
  - `change(named:)` stores a label with each snapshot, and `validateMenuItem` sets the menu title.
  - `moveZoom` uses `setZoomRange`'s neighbour limits.

### STU-C9 Projects — Low, S–M (Phase 4)

- **Plan:**
  - `SessionProject.lastOpenedAt`, written by `StudioWindowController.show`.
  - Recent recordings are handled by X-7, read lazily.
  - Regenerate the poster from the rendered file after a successful export.

---

## 9. App shell (APP)

### APP-1 Reopen does nothing — High, S (Phase 2)

- **Plan:**
  - `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)`:
    - If the status button's window is visible, call `popIdleMenu()`.
    - Otherwise open Settings ▸ General. Settings is torn down on close, so it costs no idle RAM; History would open SQLite.
    - Return `false`.
  - Never open a window on cold launch.
  - KadrTests case.
- **Spec:** docs/03 §8.1 doesn't define reopen; write it down.

### APP-2 "Show menu bar icon" — Med, S–M (Phase 4, needs APP-1)

- **Plan:**
  - Add a SettingsKit `showsMenuBarIcon` key (default true) and a GeneralPane toggle whose caption says "reopen Kadr to get back to Settings".
  - `statusItem.isVisible` follows the setting.
  - Change `.terminationOnRemoval` to `.removalAllowed`, and KVO-observe `isVisible` to write the setting back when the user removes the icon (event-driven).
- **Verify:** macOS 26's "Allow in the Menu Bar" interaction.

### APP-3 ⌘W, ⌘M, Window menu — Med, S (Phase 2)

- **Plan:** in `AppMenu.makeMenu()`:
  - add a File menu with Close (`performClose:`, ⌘W);
  - build a real Window menu (Minimize ⌘M, Zoom, Bring All to Front) and **assign `NSApp.windowsMenu`**;
  - add "Check for Updates…" to the app menu.
- **Test:** the menu contains `performClose:` ⌘W and `performMiniaturize:` ⌘M.

### APP-4 Existing windows not brought forward — Med, S (Phase 2)

- **Plan:**
  - Add `ActivationJuggler.bringForward()`, tested with the fake controller.
  - Call it, and `deminiaturize` when needed, in the existing-window branches of Settings, History, Onboarding and Help.

### APP-7 Failure presentation — Med, S–M (Phase 4)

- **Plan:**
  - Add `Kadr/UX/FailurePresenter.swift`: a `FeedbackBanner` in a `NonActivatingPanel` on the active screen.
    - It stays until dismissed (UX-24), posts a `FeedbackAnnouncement`, and ignores cancellation.
  - Use it for `application(_:open:)` parse and response errors, login-item and relaunch errors, and X-7 folder failures.
  - Split `CLIInstaller.uninstall()` into an outcome enum, so "Nothing to remove" is no longer shown when removal failed. Show the result via `ControlInlineStatus`.

### APP-8 App Intents — Low-Med, S (Phase 4)

- **Plan:**
  - Add `ToggleRecordingIntent`, and a `toggle-recording` verb in AutomationKit, the parser and `docs/AUTOMATION.md`.
  - Add RecordRegion, CaptureScrolling and CapturePreviousArea intents.
  - Add AppShortcuts for fullscreen, window, start and toggle, staying within the 10-shortcut cap.
  - CaptureText throws on empty text (X-4).
- **Verify:** `openAppWhenRun = false` in a release install.

### APP-10 Credits and licence notices — Med, S (Phase 2)

- **Plan:**
  - Add `Kadr/Credits.rtf` and `KadrEditor/Credits.rtf`: Kadr's licence plus the MIT notices for Sparkle, KeyboardShortcuts and GRDB. The standard About panel picks these up.
  - Optionally add "Acknowledgements…" to UpdatesPane.
  - Add a docs/12 release-checklist line so new dependencies add their notice.

### APP-11 / APP-13 Small Settings fixes — Low, S (Phase 4)

- **APP-11:** `isMovableByWindowBackground = false` (it can fight the card-layout drag), and check `animationBehavior` on macOS 26.
- **APP-13 (save folder row, in GeneralPane and onboarding):**
  - `abbreviatingWithTildeInPath` with `.truncationMode(.middle)`;
  - `.help(fullPath)` and `.accessibilityValue`;
  - "Use Default" and "Show in Finder" buttons.

### 9.2 Polish (APP-P, Phase 4)

- **P1. UpdatesPane state.** `automaticallyChecksForUpdates` and `lastUpdateCheckDate` aren't tracked by `@Observable`. Store tracked
  properties with write-through. S.
- **P2. Localization.** Settings tab titles, menu titles and permission names are plain `String`s, so they are missing from the catalog.
  Use `String(localized:)` and add a swiftlint rule. M.
- **P3. Drag images.** `NSImage(contentsOf:)` in `PinPanel.swift:200` and `QuickAccessCardView.swift:288` decodes
  the full capture on every drag. Use `ThumbnailLoader` at about 256 px. S.
- **P4. Dock flicker.** `ActivationJuggler.endRegularWindow` switches to `.accessory` immediately; defer it by one run-loop turn. S.
- **P5. Momentum swipe.** Covered in OUT-14/15/16.

---

## 10. Verify on device before or while implementing

These items rest on runtime behaviour that code reading can't settle:

| Item | Question |
|---|---|
| REC-9 | Does SCK deliver `.idle` frames on a static screen, and how often? |
| REC-11 | What do `contentRect` and `screenRect` mean for window streams? |
| REC-14 | What does SCK do with a stale mic device ID? |
| REC-16 | Do Esc and `CaptureAccessPrompt` work in a key but non-activated panel? |
| REC-19c | Does the teleprompter display link fire in an accessory app? |
| X-2 | Does Carbon report hotkeys held by other processes on macOS 15/26? |
| CAP-8 | Does the HUD make Kadr the frontmost app for `{app}` and focus restore? |
| CAP-11 | Do SCK display captures keep inter-window shadows on macOS 14.0–15.1? |
| APP-2 | How does `.removalAllowed` interact with macOS 26 menu bar hiding? |
| OUT-6 | Which drop targets accept the promise, and which need the file URL? |
| ED-15 | Do stitched captures over 16384 px exceed the GPU texture limit? |
| ED-1/2/4 | Visual confirmation, to be locked in by golden and render tests |

## 11. Spec and doc changes these items require (rule 7)

Land these in the same PR as the code:

- **docs/03 §1.3.** Notch trim only when the strip is empty (CAP-1); fullscreen target setting (CAP-3); capture sound reading of "silent" (X-3).
- **docs/03 §1.8.**
  - Behaviour when the stream dies or the writer fails (REC-1/2).
  - Pause implementation, if option (a) is chosen for REC-5.
  - Mic fallback on macOS 14 is still unimplemented (spec gap, no Screendrop reference).
- **docs/03 §1.9 and docs/13 T-M1.** Tidy Speech works on an edited timeline (STU-C3).
- **docs/03 §2.** Cards are optional per the after-capture matrix (OUT-1); compress produces a card (OUT-5).
- **docs/03 §3.**
  - ⌘S also writes a `.kadr` (ED-7a).
  - More arrowhead styles plus a start head (ED-2).
  - Spotlight composition (ED-9) and rotation (ED-10).
  - Presets relative to the canvas size (ED-13).
- **docs/03 §4.** Pin hover bar (OUT-8).
- **docs/03 §5.** Space opens Quick Look in History (OUT-9).
- **docs/03 §6.** Drags add a file-URL flavour (OUT-6).
- **docs/03 §8.1.** Reopen behaviour (APP-1), hidden icon (APP-2), menu additions (X-7).
- **Studio rules in docs/03, moving from docs/09.**
  - Zoom cues in source time (STU-A3), spring model and "Move" semantics (STU-B1), cursor at press (STU-B2).
  - Canvas and aspect rule (STU-A6), follow camera (STU-C1), caption wrapping and cue rules (STU-A5).
- **docs/AUTOMATION.md.** `noText` status (X-4), `toggle-recording` (APP-8).
- **docs/04 §4.3.** A decision-log entry, if REC-5 option (a) is chosen.
- **docs/08.** Mark the parity table as partial and point to this document.
- **docs/12.** Credits for new dependencies (APP-10); shadow check on macOS 14 (CAP-11).

## 12. Where Kadr is already better (keep; don't regress while porting)

- **Capture.**
  - Freeze-frame CALayer overlay: loupe, typed size, nudge, aspect lock, edge snapping, previous area, precision crosshair.
  - SCK window capture with ⇥ cycling and backdrop.
  - Scrolling capture and the colour picker.
  - OCR in the helper, with QR and tables.
  - 22 hotkeys with key-up firing, the 8-mode HUD, filename templates, WebP, HDR, staging, and consent-sheet avoidance.
- **Post-capture.**
  - File-promise drags with finalise-on-drop, four corners, sliver overflow, keyboard control.
  - Restore Recently Closed, GIF export, Trim and Studio from the card.
  - Byte-target compression in the helper.
  - Pins restored across launches, with opacity, click-through and zoom.
  - GRDB History with full-text search, retention, and drag-out.
  - The "Save All and Quit" prompt.
- **Editor.**
  - Tools: measure, stickers and image insert, smart highlighter, erase redaction, counters with formats, subject lift.
  - Editing: copy/paste/duplicate, z-order, lock, and a single command-list undo.
  - Crop: non-destructive, with canvas expansion.
  - Redaction: burned-in, jittered mosaic, dominant-edge erase, and a smart-redaction review strip.
  - Arrow bindings that survive deletion; any installed font.
  - Export: HEIC, `.kadr`, print, HDR contexts, off-main rendering.
  - Separate process with autosave and recovery.
- **Recording.**
  - Arm-then-record picker, pre-roll bar with toggles, in-place discard confirmation.
  - Level meter and "Mic silent".
  - fps, codec, HDR and mono options.
  - GIF recording, the baked-overlay mode, a notch island, a stop hotkey, CLI automation.
  - Cheap cursor artwork capture, a flexible camera bubble, a pace-mode teleprompter.
  - macOS 14 support.
- **Studio.**
  - Speech in the XPC helper on macOS 14/15, two-track labels, the cut review list.
  - GIF export, presets beyond looks, nine-slot camera snap, overlay styling.
  - Timeline snapping and frame-accurate trims, export robustness, snapshot undo.
  - Lossless quick trim, and more than 50 test files where Screendrop has none.
- **Shell.**
  - Status item states, onboarding with live permissions, `PermissionRecovery`.
  - Settings navigation, launch-at-login recovery, coalesced Sparkle checks.
  - One `AppCommand` layer for URL scheme, CLI and intents.
  - Accessibility handling for Reduce Motion, Reduce Transparency and Increase Contrast; memory discipline.

## 13. Out of scope (intentionally not ported)

- **Rule 1, zero network:**
  - cloud upload and links everywhere (`CloudUploader`, `CloudSidecarUploader`, `CloudCredentialStore`, the Cloud pane, the after-capture Upload action, History cloud URLs);
  - CDN wallpaper packs;
  - automatic speech-model download.
- **Rule 3, ScreenCaptureKit only:** Screendrop's `/usr/sbin/screencapture` still pipeline.
- **Architecture:**
  - its single-process SwiftUI canvas engine, and any code from `Engine/` (tldraw licence);
  - its `Timer`, `DispatchSourceTimer` and private-queue patterns (rules 2 and 5): port the behaviours, not the mechanisms;
  - opening the Library on every launch (idle RAM budget).
- **Dependencies:** the DockProgress package; use `NSDockTile` instead (docs/04 §12).
- **Not applicable to Kadr:**
  - ffmpeg-era compression fields;
  - Screendrop's explicit ⌘S-vs-draft studio document model (Kadr's draft/commit is deliberate, docs/09 U3.1);
  - `AnnotationEditorActivationPolicy` (Kadr's editor is its own app);
  - legacy camera `projectionVersion` migration;
  - Option-only default hotkeys;
  - Twitter and GitHub links in About.
