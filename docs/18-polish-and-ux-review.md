# Polish and UX Review: What to Change Next

> Written 2026-10-05 against `main` @ `1d4f937` (about 140k lines of Swift: the agent, the editor
> app, the XPC helper, the CLI and 16 packages). This plan answers one question: **after the work
> that landed from docs/14 and docs/17, what still stands between Kadr and a polished,
> well-designed macOS app, and in what order should it be fixed?**
>
> `03-features.md` stays authoritative for behaviour, `04-swift-architecture.md` for structure and
> `CLAUDE.md` for the hard rules. Item IDs from docs/14 (`UX-n`) and docs/17 (`T-…`) are kept where
> an item is theirs; new items use the area prefixes in §4.

## 0. Verdict

**The foundations are good, and most of docs/17 has landed. What is left is a short list of
day-one defects on the primary flows, then a set of cross-app consistency projects.**

What the review found in good order:

- Of the 60-odd docs/17 items checked, most are fixed in code. Every docs/17 P0 that the reviews
  re-checked is fixed, including the data-loss set (hover ⌫, the pause gap, stale exports,
  retention wipes, Esc discarding typed text).
- `make lint` and `make check` pass with 0 violations. All 16 package suites pass, and the app
  suite passes 490 of 491 tests (§2).
- Hygiene is unusually clean: 0 TODO/FIXME, 8 lint suppressions, 0 timers in the agent, 0
  `DispatchQueue.main`, typed geometry with no flip or scale bug found on the capture path.

What still needs work, in three groups:

1. **Eight defects a user meets on day one** (§3, Phase 1). The two worst are in the editor:
   Copy straight after drawing an annotation puts nothing pasteable on the clipboard (ED-2), and a
   capture opened from a card is edited as a hidden copy, so ⌘S and Move to Trash act on the wrong
   file (ED-1).
2. **About forty smaller defects and gaps**, spread across every area (§3, Phases 2–3).
3. **Five cross-app projects** that no single fix closes (§5): one design-token set, one feedback
   model, accessibility-setting coverage, localization plumbing, and a test target for the editor
   app.

Rough size for one engineer: Phase 1 about a week, Phase 2 two to three weeks, Phase 3 three to
four weeks, Phase 4 open-ended.

## 1. How this was produced, and its limits

**Method**

- Seven parallel reviews each read one area in full against docs/03 and the open items of docs/14
  and docs/17: shell and settings; capture; cards, pins, History and automation; recording; the
  annotation editor; the studio and helper; and cross-cutting quality (measured repo-wide).
- The lint, layering and test gates were run on this machine (§2).
- Every Phase 1 item, and most of the P1 items, were then re-read by hand against the code while
  this document was written. Those carry **✔** in §4.

**Limits**

- **Nobody ran Kadr.** Every finding comes from reading source. Each item is marked either
  *traced* (the code path was followed end to end) or *device* (it is a reading of structure that
  a running app has to confirm). Treat *device* items as hypotheses; §7 collects them.
- Visual quality (spacing, colour, motion feel) cannot be judged from source. §5.1 measures
  inconsistency, not taste. A screenshot pass on a real build is still owed (docs/14 Phase D0).
- `make perf` and `make size-gate` were not run: they kill running Kadr instances or make a fresh
  archive.

### Severity and effort

| Level | Meaning |
|---|---|
| **P0** | An ordinary action on a primary flow gives the wrong result or acts on the wrong file. |
| **P1** | A user hits it in the first week. |
| **P2** | Polish, HIG conformance, accessibility depth, edge cases. |
| **P3** | Nice to have. |

Effort: **S** ≤ ½ day · **M** 1–3 days · **L** > 3 days.

## 2. Gate results (2026-10-05, clean `main`)

| Gate | Result | Notes |
|---|---|---|
| `make lint` | ✅ pass | 0 SwiftLint violations in 989 files; no SwiftFormat changes. |
| `make check` | ✅ pass | Layering, zero-network and SCK-only checks pass. The size check measured a Debug build product (46 MB stripped) and says so itself; the real number needs `make size-gate`. |
| Package tests | ✅ 16/16 pass | About 2,430 tests. VisionServices, which failed 2 tests on macOS 27 in docs/17, now passes (38 tests). |
| `make test-app` | ❌ 490/491 | `VisionClientTests` "The helper recognises text and sends it back" times out (`.timedOut`, 28.7 s). docs/17 saw the same failure and put it down to the unsigned XPC helper in a test build; that cause is still unconfirmed. The gate now fails honestly (exit 65) instead of being masked. |
| `make perf`, `make size-gate` | not run | See §1. |

## 3. The plan

### Phase 1: fix the primary flows (about 1 week)

**Exit:** capture → annotate → copy/save, capture → window mode, scrolling capture, studio copy and
export retry, and Export Diagnostics all do what their labels say.

| ID | Item | Sev | Effort |
|---|---|---|---|
| ED-2 | Copy after drawing puts no image on the clipboard ✔ | P0 | S |
| ED-1 | Capture opened from a card is edited as a hidden copy ✔ | P0 | M |
| CAP-1 | W on the area overlay enters a window mode with no windows ✔ | P1 | S |
| CAP-2 | Esc during a scrolling capture discards every frame ✔ | P1 | S |
| CAP-3 | A click with 1 pt of travel takes a capture ✔ | P1 | S |
| STU-1 | Studio Copy leaves a clipboard entry that dies when the window closes ✔ | P1 | S |
| STU-2 | "Retry" on studio failure banners does nothing ✔ | P1 | S–M |
| SH-1 | Diagnostics export includes the teleprompter script and file names ✔ | P1 | S |
| X-5a | The silent failures on user actions listed in §5.2 ✔ (studio commit) | P1 | S each |

### Phase 2: first-week defects (2–3 weeks)

Every remaining P1 in §4, in this order:

1. **Wrong or lost output:** REC-1 (silent mic downgrade), REC-3 (still ending cut short), ED-3
   (proxy icon drags out un-redacted pixels), ED-4 (slider drags evict undo history), OUT-2
   (staged drag-out), STU-4 (no way to transcribe without Find Cuts).
2. **Trust:** SH-2 (session-only History wipe without confirmation), REC-2 (a take with no visible
   Stop), SH-3 (background updates invisible).
3. **Needs a device first:** OUT-1 (card click keeps the keyboard), CAP-4 (island captures show the
   inactive app), REC-4 (crash recovery of an in-flight segment), REC-5 (sleep and wake), STU-3
   (scrubbing a zoomed timeline), CAP-5 (cursor and HDR ignored on macOS 15.2+).
4. **Stop the bleeding on process:** X-6 (KadrEditor test target), SH-4 (Finder restart on every
   capture).

### Phase 3: polish and consistency (3–4 weeks)

- All P2 items in §4.
- The five cross-app projects in §5.
- The open docs/14 and docs/17 items in §6.

### Phase 4: depth (backlog)

P3 items, and the feature-depth gaps in §4 (editor snapping and guides, slow motion, HDR export,
transcript correction).

## 4. Findings, by area

Each item gives the evidence, what the user experiences, the change, and how sure the finding is.
Paths are relative to the repository root. `EUI/` stands for
`Packages/EditorUI/Sources/EditorUI/`.

### 4.1 Annotation editor (ED)

**ED-1 · A capture opened from a card is edited as a hidden copy · P0 · M · traced ✔, confirm on device**

- **Evidence:** Annotate finalises the capture into the save folder (Desktop by default) and opens
  that file with `NSWorkspace` (`Kadr/QuickAccess/QuickAccessManager+Actions.swift:153-183`,
  `Kadr/QuickAccess/EditorLauncher.swift:55`). The editor copies every non-`.kadr` file outside
  `Application Support/Kadr` into `Kadr/Imported` (`KadrEditor/EditorAppDelegate.swift:57-86`). It
  cannot tell the agent's hand-off from a Finder double-click.
- **Experience,** for any capture with no sibling `.kadr`:
  - ⌘S opens a Save As sheet instead of saving beside the original
    (`KadrEditor/EditorWindowController+Export.swift:92-95,157`).
  - Move to Trash removes the hidden copy and leaves the real capture where it was.
  - Each Annotate makes another copy, and nothing sweeps `Imported`.
  - Crash recovery is keyed to the copy's path, so reopening from the card never offers it.
- **Why it may have gone unnoticed:** captures with a default look or auto-beautify get a sibling
  `.kadr` and take the in-place path.
- **Change:** have the agent mark its hand-off (a launch argument or an `owned` flag) and edit
  those files in place. Keep copy-on-open for Finder and ⌘O only. Sweep `Imported` at launch. Add
  an integration test: card → edit → ⌘S on a Desktop path.

**ED-2 · Copy straight after drawing puts no image on the clipboard · P0 · S · traced ✔**

- **Evidence:** a newly placed annotation is selected
  (`EUI/EditorDocumentModel+Pointer.swift:158-160`). With a selection, both the toolbar Copy button
  (`EUI/EditorRootView.swift:145-159`) and ⌘C (`KadrEditor/EditorWindowController+Commands.swift:25-31,149-154`)
  write only the private `app.kadr.annotations.json` type, then show the "Copied" toast.
- **Experience:** draw an arrow, press Copy, paste into Slack: nothing arrives. docs/03 says ⌘C
  copies flattened.
- **Change:** always write the flattened PNG, and add the annotation JSON as a second pasteboard
  type when there is a selection. Kadr's own paste already prefers the JSON.

**ED-3 · After a save, the title-bar proxy drags out the `.kadr`, which holds the un-redacted original · P1 · S–M · traced**

- **Evidence:** `rebind(to: targets.document)` prefers the project (`EUI/EditorSaveTargets.swift:75-77`);
  the project stores the untouched base PNG (`Packages/AnnotationModel/.../KadrDocumentFile.swift:60-63`).
- **Experience:** dragging the proxy into Mail sends the pixels the user blurred.
- **Change:** keep `representedURL` on the flattened image. Add a file-promise drag chip that
  renders the flattened image. When a document has redactions, say once in the save flow that the
  project keeps the original pixels.

**ED-4 · Some inspector sliders push one undo step per tick · P1 · S · traced**

- **Evidence:** image Size, Opacity and Corners (`EUI/EditorStylePane.swift:80-106`) and redaction
  Strength (`EUI/EditorToolOptions.swift:127-135`) call `document.perform` on every change. The
  stack is capped at 128 (`Packages/AnnotationModel/.../AnnotationDocument.swift:12,398-402`).
- **Experience:** one long drag discards earlier undo steps, and ⌘Z walks back tick by tick.
- **Change:** route them through `rewriteSelectionLive` with `onEditingEnded`, as stroke width
  already does. Test that N slider writes make one history entry.

**P2**

| ID | Item | Evidence | Change | Effort | Confidence |
|---|---|---|---|---|---|
| ED-5 | ⌘Z while typing removes the text box under a live field; placing and typing are two undo steps | `AnnotationDocument.swift:275-283,358-364`; `EUI/EditorDocumentModel+Binding.swift:42-63` | `allowsUndo` on the field; `undo`/`redo` close the open gesture; fold place-and-type into one gesture | S | model traced, routing device |
| ED-6 | Tool letters fail on non-Latin layouts (Ukrainian included) and fire with ⌥/⌃ held | `EUI/AnnotationCanvasView+Navigation.swift:136-145` | Match by key code; require no modifiers | S | traced |
| ED-7 | No snapping or guides, no ⌥-drag duplicate, no align/distribute, ⇧-click does not extend selection, repeated paste stacks on one point | `EUI/AnnotationCanvasView.swift:419-431`; `EditorWindowController+Export.swift:277-283` | Start with edge and centre snapping plus ⌥-drag duplicate | M–L | traced by absence |
| ED-8 | Raw Swift error text in banners ("…RenderError error 0") | `Packages/AnnotationRender/.../AnnotationExportRenderer.swift:25-28`; `KadrDocumentFile.swift:43-47` | `LocalizedError` for each case; tolerate unknown command types so an older build says "newer version", not "malformed" | S | traced |
| ED-9 | Plain Tab is trapped in the canvas under Full Keyboard Access | `EUI/CanvasAccessibility.swift:87-100` | Stop wrapping; let focus leave after the last item | S | traced |
| ED-10 | Autosave rewrites the whole base PNG 1.5 s after every edit; recovery ignores rotate/flip-only work | `KadrEditor/EditorWindowController+Autosave.swift:20,113-151` | Write the base once and the JSON separately | M | traced |
| ED-11 | Menu and toolbar gaps: no Tools/Arrange menu, no canvas context menu, no italic or underline, inspector shortcut shown as ⌥⌘I in one place and ⌘I in another, studio items in annotation windows | `EUI/EditorToolbar.swift:77,83`; `KadrEditor/EditorAppDelegate+Menu.swift:206`; `AnnotationStyle.swift:295` | Add the menus (they also make tool letters discoverable); add italic/underline per docs/03 | M | traced |
| ED-12 | Save As has no format or quality control; Export Size is not stored in the project; DPI tag wrong after a downscale | `EditorWindowController+Export.swift:155-166,303-309` | Accessory view with format and quality; persist Export Size | M | traced |
| ED-13 | Export of a CMYK or indexed image probably fails; one layer holds the full base image for very tall captures | `AnnotationExportRenderer.swift:157-187`; `AnnotationCanvasView.swift:151` | Fall back to sRGB; test a 30,000 px capture | S + device | device |

**P3:** insert, open and print still use app-modal panels (`EditorWindowController+Export.swift:216,253`);
no window restoration or launch-time recovery list; Help is three paragraphs and ignores the topic
once the window exists (`KadrEditor/EditorHelp.swift:92-96`); nothing in export is cancellable.

### 4.2 Capture (CAP)

**CAP-1 · W on the area overlay enters a window mode with no windows · P1 · S · traced ✔**

- **Evidence:** the window list is fetched only when the overlay opens in window mode
  (`Kadr/Capture/AreaCaptureCoordinator.swift:234-249`). Switching later only propagates the mode
  (`Packages/SelectionUI/.../SelectionOverlayController.swift:361-367`).
- **Experience:** the hint says "W for a window". After W the screen says "Click a window", but
  nothing highlights and clicks do nothing.
- **Change:** fetch the window list concurrently with the freeze and hand it to the overlay after
  it is shown. This also removes the serial wait that makes window capture open slower (CAP-9).

**CAP-2 · Esc during a scrolling capture discards every frame · P1 · S · traced ✔**

- **Evidence:** the HUD registers a system-wide Escape that calls `cancel()`
  (`Kadr/Capture/ScrollCaptureHUD.swift:59-63`), which deletes all frames
  (`Kadr/Capture/ScrollCaptureCoordinator.swift:337-348`).
- **Experience:** the user is working in the page being captured. An Esc meant for a cookie banner
  or find bar destroys a long capture with no confirmation.
- **Change:** while capturing, make Esc stop and stitch, or require a second Esc. Keep discard on
  the Cancel button. Show the keys in the HUD.

**CAP-3 · A click with 1 pt of travel takes a capture · P1 · S · traced ✔**

- **Evidence:** `SelectionInteraction.end()` accepts any non-empty rect
  (`Packages/SelectionUI/.../SelectionInteraction.swift:155-160`).
- **Experience:** a twitchy click dismisses the overlay, overwrites the clipboard with a 2×2 px
  image and puts up a card.
- **Change:** treat drags under about 4 pt per side as no selection and stay on the overlay.

**CAP-4 · Island-started captures can show the target app in its inactive state · P1 · M · device**

- **Evidence:** the island activates Kadr; on pick it yields activation asynchronously and the
  freeze starts in the same turn (`Kadr/Capture/AllInOneHUD.swift:141-149,184-186`).
- **Change:** before freezing, wait for the target's activation (cap about 150 ms). Better: make
  the island a key, non-activating panel like the selection overlay, so activation never moves.

**CAP-5 · "Include cursor" and HDR are dropped for display and area captures on macOS 15.2+ (below 26) · P1 · S–M · traced, effect device**

- **Evidence:** the direct path calls `SCScreenshotManager.captureImage(in:)` and discards both
  settings (`Packages/CaptureCore/.../CaptureEngine+RectCapture.swift:213-215`).
- **Change:** use the filter path when either is requested, or disable the options there with an
  explanation.

**P2**

| ID | Item | Evidence | Change | Effort | Confidence |
|---|---|---|---|---|---|
| CAP-6 | Arrow-key nudge only works in the off-by-default confirm mode; step is 1 pt, spec says 1 px | `SelectionInteraction.swift:237-249`; `SelectionOverlayView+Keyboard.swift:210-228` | Carry a nudge offset through `drag()`; step by `1/scale` | S–M | traced |
| CAP-7 | Scroll hot keys stay live through stitching: Return does not press the alert's default button, Esc deletes frames the alert is offering to export | `ScrollCaptureHUD.swift:72-73`; `Kadr/Capture/TransientHotKeys.swift:83-87` | Stop the keys in `showStitching()` | S | traced |
| CAP-8 | A scroll stream that macOS stops is never surfaced; the last buffered frames can be dropped on Stop | `Packages/CaptureCore/.../ScrollCaptureSession.swift:139-147,277-279` | Forward the stop and auto-stitch with a notice; drain before returning | M | half traced |
| CAP-9 | Window list awaited inside the hotkey-to-overlay interval; neither headline PRD §8 budget is checked by any gate | `AreaCaptureCoordinator.swift:226-249` | Fixed by CAP-1; add a signpost check to `check-perf.sh` or a docs/12 row | M | traced |
| CAP-10 | The teaching pill sits mid-screen during the drag, on every display | `Packages/SelectionUI/.../HintLayerGroup.swift:49-54,110-111` | Bottom-centre, active display only, hide once a rect exists | S | traced, visual device |
| CAP-11 | Failure banners show internals ("Display 69734272 is no longer connected") | `Packages/CaptureCore/.../CaptureError.swift:74-83` | User-facing messages; IDs in the log only | S | traced |
| CAP-12 | Scrolling frame editor is pointer-only and absent from the accessibility tree | `Kadr/Capture/ScrollRegionEditor.swift:225-447` | Arrow keys through `TransientHotKeys`; a proxy element like the selection overlay's | M | traced |

**P3:** the cursor is always a crosshair, even over handles and in window mode; a typed size is in
points with no unit shown, so "1280x720" yields 2560×1440 on Retina
(`NumericSizeEntry.swift:95-101`); a running fullscreen countdown is not cancelled when an overlay
opens; `Kadr-Scroll-*` temp folders are never swept after a crash; the island's position is not
remembered.

### 4.3 Cards, pins, History, automation (OUT)

**OUT-1 · Clicking a card takes the keyboard and never gives it back · P1 · S–M · mechanism traced ✔, effect device**

- **Evidence:** the card panel calls `makeKey()` on every mouse-down, including on Copy or Pin
  (`Kadr/QuickAccess/QuickAccessOverlayPanel.swift:151-156`). Nothing resigns key until the panel
  closes.
- **Experience (to verify first):** click Copy, press ⌘V in Slack, nothing pastes. Further typing
  can hit card keys: ⌫ trashes the capture, Return saves and dismisses.
- **Change:** do not take key for clicks on action buttons, and hand key back after a
  pointer-initiated action and when the pointer leaves the stack.

**OUT-2 · Drag-out of a staged card leaks the staging path and can duplicate the file · P1 · M · logic traced, receivers device**

- **Evidence:** the card publishes the staging path as `.fileURL`
  (`Kadr/QuickAccess/QuickAccessCardView.swift:295`); the promise path finalises into the save
  folder and then copies (`Kadr/QuickAccess/FilePromiseDrag.swift:164-174`); staged files are swept
  after 24 h (`Packages/MediaExport/.../StagingArea.swift:141-157`).
- **Experience:** an app that keeps the path holds a link that is deleted a day later. A drop into
  Finder leaves two copies. A drop onto the save folder itself can fail.
- **Change:** on an accepted drop whose promise was not resolved, finalise the file or exempt it
  from the sweep. For promise drops, copy from staging without finalising.

**P2**

| ID | Item | Evidence | Change | Effort | Confidence |
|---|---|---|---|---|---|
| OUT-3 | An unopenable History database gives a silently empty History forever | `Kadr/History/HistoryController.swift:212-213,435-438` ✔; `HistoryStore.rebuild()` has no caller | Move the file aside and rebuild from sidecars; show the error with "Rebuild Library"; test with a corrupted file | M | traced |
| OUT-4 | An editor save re-ingests the capture dated "now", with no app name or OCR; rotate/flip never reach History | `Kadr/QuickAccess/QuickAccessManager+EditorSaves.swift:31-54` ✔; `+Transform.swift:45-53` | A `replaceContent(previousHash:with:)` store operation that keeps id and metadata | M | traced |
| OUT-5 | Deletions inside the Undo window are lost on quit | `Kadr/AppDelegate+Termination.swift:31-40` ✔ | Commit pending card and History deletions at termination | S | traced |
| OUT-6 | History delete puts `<sha256>.png` files in the Trash; no link back to the real file | `Packages/HistoryKit/.../HistoryStore.swift:400-403`; `HistoryDatabase.swift:12-25` | Schema v2 with the original path or bookmark; closes most of T-OUT-8 and T-OUT-10 | M | traced |
| OUT-7 | History filter state is invisible; an empty filter result says "No captures yet" | `Kadr/History/HistoryView+Toolbar.swift:22-55`; `HistoryView.swift:298-306` | `Picker` inside `Menu`; a filter-aware empty state with Clear | S | traced |
| OUT-8 | History falls short of Finder: context menu and drag act on one item with several selected; VoiceOver cannot select or open a cell; no type-select; double-click opens a card in a corner | `HistoryView.swift:175-197,260-296`; `HistoryView+Cell.swift:62-64` | Act on the selection; real accessibility actions; open in Quick Look or the editor | M | traced |
| OUT-9 | An open History window goes stale; OFFSET paging skips or repeats rows after a change | `HistoryController.swift:264-266,441-461` | Keyset pagination; insert and remove rows on ingest and commit | S–M | traced |
| OUT-10 | Search ignores app names unless the OCR index has run | `Packages/HistoryKit/.../HistoryIndexing.swift:69-76` | Add `application_name` to the fallback | S | traced |
| OUT-11 | Card thumbnails decode on the main thread, up to three times per capture | `Kadr/QuickAccess/QuickAccessCardChrome.swift:43-47` | Decode detached with one small cache, as `PinPanel` does | S | traced |
| OUT-12 | Compress and GIF export share one XPC client and disconnect it under each other | `QuickAccessManager+Compress.swift:26`; `+GIF.swift:25` | One client per operation, or refcount | S | logic traced |
| OUT-13 | Automation consent gaps: decisions live in plain UserDefaults; a grant is permanent and all-or-nothing per app (a browser included); full URLs logged as public | `Packages/AutomationKit/.../AutomationConsent.swift:60-72,131-134`; `AppDelegate+Termination.swift:65` | Keychain-backed decisions; never remember browsers, or scope silent and `path=` verbs separately; show the file or region in the prompt | M | traced |
| OUT-14 | Shortcuts and CLI: Pin Image rejects in-memory images; capture intents take no action parameter; `kadr help` points at a repo file | `Kadr/Automation/KadrAppIntents.swift:181-183`; `KadrCLI/main.swift:34` | Write image data to scratch; add the parameter; `kadr help <verb>` | S | traced |
| OUT-15 | Pins: zoom ignores a manual resize and grows away from the pointer; the menu advertises ⌘W and ⌘⌥L that are not handled; the click-through shortcut is hard-coded in three labels although it is rebindable | `Kadr/Pins/PinPanel.swift:299-307,361,376,440`; `PinContentView.swift:64-74` | Anchor zoom at the pointer; handle or remove the shortcuts; render the live binding | M | traced |
| OUT-16 | A two-finger nudge of 6–8 pt dismisses a card; the card does not track the finger | `Kadr/QuickAccess/OverlaySwipe.swift:16-21` | Finger-tracked offset with distance and velocity thresholds and a spring back | M | thresholds traced, feel device |

**P3:** `moveFile` and `finalize(to:)` remove the destination before moving (use `replaceItemAt`);
History rename swallows errors but updates the UI; a batch delete gets both a confirmation and an
Undo; `SearchField.swift` is dead code.

### 4.4 Recording (REC)

**REC-1 · A microphone that could not be used is reported almost invisibly · P1 · S · traced**

- **Evidence:** the downgrade notice renders only inside the elapsed-time element
  (`Kadr/Recording/RecordingControlBar+Views.swift:262-268`), which the notch layout omits
  (`Kadr/Recording/RecordingNotchIsland.swift:122`). In the floating bar it is caption text for 5 s
  and is never announced.
- **Experience:** the chosen microphone is unplugged or unpermitted, and the user narrates ten
  minutes into a silent file.
- **Change:** show the notice in the notch too, keep a persistent "No mic" glyph for the whole
  take in both layouts, and announce it.

**REC-2 · A take can run with no Kadr indicator and no on-screen Stop · P1 · S · traced**

- **Evidence:** with "show control bar" off the bar is dismissed
  (`Kadr/AppDelegate+Commands.swift:214-217`), and nothing forces the status item visible while
  recording (`Kadr/StatusItem/StatusItemController+Icon.swift:44-55,167-169`).
- **Change:** force the status item visible while busy. If the bar is off and no stop shortcut is
  bound, show the bar anyway or warn at start.

**REC-3 · A still ending is cut short · P1 · S–M · mechanism traced ✔, file effect device**

- **Evidence:** idle `.clock` samples return before `writer.append`
  (`Packages/RecordingCore/.../RecordingEngine.swift:383-389`), and `endSession` is called only
  when trimming (`SegmentWriter.swift:283-290`). The comment at `RecordingEngine.swift:89-91`
  promises "a static tail survives Stop", but nothing re-appends the held frame at close.
- **Experience:** stop by hotkey or automation after N still seconds with audio off, and the file
  is N seconds short.
- **Change:** remember the last idle timestamp and re-append the held frame at it on close, or end
  the session at the last seen time. Test through a real writer; the fake cannot see this.

**REC-4 · Crash recovery of the in-flight segment is unproven · P1 · M · device**

- **Evidence:** segments are fragmented `.mp4` (`SegmentWriter.swift:126,164`). No test kills a
  writer, and docs/12 has no kill row. An unreadable segment is retried silently on every launch
  (`Kadr/Recording/RecordingCrashRecovery.swift:81-82`).
- **Change:** run a `kill -9` test on a device. If it fails, write `.mov` and remux at stitch.
  Report "could not recover — Show in Finder" once.

**REC-5 · No handling of sleep, lid close or wake · P1 · S–M · absence traced ✔, effect device**

- **Evidence:** no `willSleep` or `didWake` observer exists anywhere; the elapsed clock is wall
  time (`Kadr/Recording/RecordingCoordinator+Plumbing.swift:149`).
- **Change:** on `NSWorkspace.willSleepNotification`, pause (or stop and save) and say so on wake.

**P2**

| ID | Item | Evidence | Change | Effort | Confidence |
|---|---|---|---|---|---|
| REC-6 | Resume can open on the pre-pause picture until something on screen changes | `RecordingEngine.swift:381,402` | Keep the held frame updated while paused | S | traced |
| REC-7 | Three state-machine holes: cancel's trailing task can knock a new take back to idle; a stream death during `.starting` is dropped; quit waits on a stitch with no timeout | `Kadr/Recording/RecordingCoordinator+Control.swift:227-233,291-309`; `RecordingCoordinator.swift:159` | Guard with the start generation; replay a pending interruption; bounded wait | S | traced |
| REC-8 | Disk space is checked once before the take, against a fixed 1.5 GB | `Kadr/Recording/RecordingDiskSpace.swift:11` | Check from the existing tick; auto-stop with margin; scale the floor | S | traced |
| REC-9 | Notch controls dock to the built-in display whatever is being recorded | `Kadr/Recording/RecordingNotchShape.swift:10-12` | Dock only when the notch screen is the recorded or pointer screen | S | logic traced |
| REC-10 | No device hot-plug handling; camera picker is right-click only; with access denied, "Allow" does nothing | `Kadr/Recording/RecordSetupView.swift:277`; `CaptureAccessPrompt.swift:87-93` | Observe device notifications while live; give the camera a menu; show "Open Settings" when denied | M | traced |
| REC-11 | No Pause/Resume shortcut; the compact notch has no Stop without hover (UX-16); the teleprompter cannot be nudged; clicks on the teleprompter and camera bubble are recorded | `Kadr/Hotkeys/HotkeyCenter.swift:36`; `Kadr/Recording/TeleprompterPanel.swift:24-26`; `Kadr/AppDelegate.swift:216-218` | Add the shortcut; click expands the compact notch; scroll-wheel nudge; add both panels to the chrome list | M | traced |
| REC-12 | Status menu shows live Discard and Restart while the take is saving; Discard asks for confirmation, then does nothing | `Kadr/StatusItem/StatusItemController.swift:234-281` | One disabled "Saving recording…" row | S | traced |

**P3:** bar and camera-bubble placement are static variables and forgotten on relaunch
(`RecordingControlBar.swift:44`, `CameraPreviewPanel.swift:19-22`); off-state controls differ from
on only by opacity; the audio meter is hard-coded green; alert bodies are raw AVFoundation text.

### 4.5 Studio and helper (STU)

**STU-1 · Copy leaves a clipboard entry that dies when the window closes · P1 · S · traced ✔**

- **Evidence:** Copy writes only a file URL into `$TMPDIR/Kadr Studio Staging`
  (`EUI/StudioDocumentModel+Export.swift:39-40,118-122`); closing the window or quitting purges
  that folder (`EUI/StudioDocumentModel+Close.swift:32`).
- **Experience:** copy, close the studio, paste: nothing arrives.
- **Change:** keep staged renders past close and sweep them by age at the next editor launch.

**STU-2 · "Retry" on every failure banner does nothing · P1 · S–M · traced ✔**

- **Evidence:** the handler clears the banner and acts only when the title contains "40%"
  (`EUI/StudioRootView.swift:391-395`).
- **Change:** carry the operation in the action (`.retry(.export(url))`, `.retry(.transcribe)`)
  and re-run it. Test each failure's primary action.

**STU-3 · Scrubbing a zoomed timeline fights the pointer · P1 · S · mechanism traced ✔, feel device**

- **Evidence:** `PlayheadFollower` re-centres the scroll view on every playhead change whenever
  zoom is above 1, playing or not (`EUI/StudioTimelineView.swift:168-170,459-470`).
- **Change:** follow only while playing, scroll only when the needle leaves the visible range, and
  suspend following during a drag.

**STU-4 · A transcript and captions can only be reached through "Find Cuts…" · P1 · S · traced**

- **Evidence:** Captions render only when a transcript exists
  (`EUI/StudioInspector+Speech.swift:192-193`), and only `tidySpeech()` produces one
  (`EUI/StudioDocumentModel+Speech.swift:114-129`).
- **Change:** add a "Transcribe" action that proposes no cuts, and always show the Captions section
  with a "Transcribe to add captions" state.

**P2**

| ID | Item | Evidence | Change | Effort | Confidence |
|---|---|---|---|---|---|
| STU-5 | Export deletes the destination before rendering, with no free-space check | `Packages/StudioRender/.../StudioRenderer+Write.swift:25,42-46` | Render to a sibling temp file and `replaceItemAt`; compare the estimate with free space | M | traced |
| STU-6 | Copy and Share silently use whatever the Export popover last held (a GIF, 480p) | `EUI/StudioDocumentModel+Export.swift:113-114,140` | A fixed, stated preset, or name it in the menu item | S | traced |
| STU-7 | "Already exported" trusts the path, not the file | `Packages/StudioSession/.../SessionDocument.swift:151` | Store size and modification date in the stamp | S | traced |
| STU-8 | The helper timeout cannot fire for a hung helper; speech timeouts read "Text recognition did not finish" | `Packages/Shared/.../VisionClient.swift:23-25,266-320` | Invalidate the connection on timeout; per-operation messages | S | traced from task-group semantics |
| STU-9 | Transcription progress sits at 18% for minutes; a hard 30-minute ceiling | `Packages/VisionServices/.../SpeechXPCHandler.swift:25-50` | Progress from result ranges, or indeterminate with elapsed time; scale the timeout | M | traced |
| STU-10 | Transcript: search hides non-matching words; a cut word cannot be restored there; "Filler words" is English-only while every locale is offered | `EUI/StudioDocumentModel+Speech.swift:284-286,337-342`; `StudioRender/.../TranscriptCutPlanner.swift:99-101` | Find in place with next/previous; Restore; per-language lists or hide the toggle | M | traced |
| STU-11 | Two keyboard models: J/K/L and friends die after a click in the inspector; Delete and the trash button disagree on what is selected (T-STU-8); ⌘E during crop opens a popover later | `EUI/StudioTimelineView.swift:78-113,314-315`; `StudioTransportBar.swift:103-109,258` | Route bare keys through the responder chain; one selection rule | M | traced |
| STU-12 | Studio window has no frame autosave, no title-bar proxy, no remembered inspector or transcript state | `KadrEditor/StudioWindowController.swift:107-117` | Frame autosave and persisted panel state | S | traced |
| STU-13 | Export sheet: "Quality" changes meaning with "Compress"; no percent or ETA; every export activates Finder | `EUI/StudioExportSettings.swift:22-42`; `StudioRootView.swift:346-353` | One size-versus-quality control; percent and ETA; an in-window "Exported · Show in Finder" banner with a draggable file | M | traced |
| STU-14 | First open adds zooms from clicks silently, outside undo | `EUI/StudioDocumentModel+Presets.swift:46-62` | A one-time notice with Remove; trigger from the model, not the inspector's `onAppear` | S | traced |
| STU-15 | Long recordings: every filmstrip tile is laid out eagerly; the transcript re-flows every word on each active-word change | `EUI/ClipFilmstripLane.swift:16-45`; `StudioTranscriptPanel.swift:243-262` | Window both to the visible range | L | device |

**P3:** the trim window fails silently when trimming cannot begin
(`KadrEditor/TrimWindowController.swift:91-94`) and its export guard flag is never read; SRT/VTT
are written silently and overwrite; a failed player item shows a black well; no slow motion; every
frame renders through sRGB (no HDR or P3).

### 4.6 Shell, onboarding, settings (SH)

**SH-1 · Diagnostics export contradicts its privacy promise · P1 · S · traced ✔**

- **Evidence:** the snapshot dumps every key in the preferences domain
  (`Kadr/Diagnostics/DiagnosticsSnapshot.swift:123-150,204`), and the teleprompter script is stored
  there (`Packages/SettingsKit/.../AppSettings.swift:222-223`). The UI says "no captures or file
  names" (`Kadr/Settings/AdvancedPane.swift:73-74`).
- **Experience:** a tester pastes the summary into a public issue with their script, backdrop file
  name, save-folder name and consented app names in it.
- **Change:** build the block from an allow-list of bool, enum and numeric keys; report strings
  and paths as "set". Test that a script or path never appears in the summary.

**SH-2 · "This session only" wipes History at the next launch with no confirmation · P1 · S · traced ✔**

- **Evidence:** the pane confirms only when the preview already has something to delete
  (`Kadr/Settings/HistoryPane.swift:53-55,86-99`), and session-only is inert until the next launch,
  so the preview is empty. The setting is also written before the alert is answered.
- **Change:** confirm on selecting session-only, with the count and size that will go. Hold the
  picker in a draft and write on confirm.

**SH-3 · An update found in the background is practically invisible · P1 · S–M · traced**

- **Evidence:** a scheduled find is shown only as a row in the right-click menu
  (`Kadr/StatusItem/StatusItemController+Application.swift:42-53`); left-click opens the island.
- **Change:** a badged status icon, a row in the island, and a line in Settings ▸ Updates.

**SH-4 · Hiding desktop icons restarts Finder on every capture · P1 · M · restart traced ✔, side effects device**

- **Evidence:** `killall Finder` on every hide and show, then a fixed 250 ms wait
  (`Kadr/Desktop/DesktopHygiene.swift:33-38,79-88,181-190`). This is the open half of T-CAP-12.
- **Change:** cover the desktop with a borderless window just above the icon level showing the
  wallpaper or a colour. No restart, no delay, nothing to restore after a crash. It also replaces
  the wallpaper swap and makes SH-9 moot.

**P2**

| ID | Item | Evidence | Change | Effort | Confidence |
|---|---|---|---|---|---|
| SH-5 | Reset All Settings keeps automation consent and resets shortcuts unannounced; Remove All Data leaves the login item; Restore All Shortcuts has no confirmation | `Kadr/Settings/AdvancedPane.swift:86-90`; `Kadr/AppDelegate+DataReset.swift:30-70`; `ShortcutsPane.swift:21-24` | Reset consent and the login item; name shortcuts in the dialog; confirm | S | traced |
| SH-6 | Onboarding's "After capturing" radio writes a retired setting that overwrites the per-kind matrix | `Kadr/Onboarding/OnboardingView.swift:190-195`; `AppSettings.swift:23-30` | Derive from the matrix; write only on an explicit change | S | traced |
| SH-7 | Four actions give no feedback: Install speech model…, Export Diagnostics…, Check Now when Sparkle fails to start, a failed `kadr://` command | `Kadr/Settings/TeleprompterSection.swift:55-58,88-96`; `AppDelegate+Diagnostics.swift:40-53`; `Kadr/Updates/UpdaterManager.swift:224`; `AppDelegate+Termination.swift:57-66` | Route through `ControlInlineStatus` or `FailurePresenter` with a progress state | S each | traced |
| SH-8 | Focus is taken and not returned by the permission-recovery alert and the menu-bar coach popover | `Kadr/Onboarding/PermissionRecovery.swift:51`; `Kadr/UX/CoachPopover.swift:101-109` | Use the temporary-activation lease | S | device |
| SH-9 | "Custom image" wallpaper option has no way to choose an image | `Kadr/Settings/CapturePane.swift:197-201` | Add Choose…, or drop the case | S | traced |
| SH-10 | The status item tells VoiceOver "Opens the capture island" while a press would stop the recording | `StatusItemController+Icon.swift:151-159` | Label and help per state | S | traced |
| SH-11 | `KadrSlider` is low-contrast at rest (9% fill on a 4% track) with no Increase Contrast variant | `Packages/ControlKit/.../SliderTrackView.swift:142-162` | Raise the resting values; branch on contrast | S | device |
| SH-12 | The keystroke overlay needs Input Monitoring, but Help and Settings name only Accessibility, and it skips silently without it | `Kadr/Help/KadrHelp.swift:110-111`; `Kadr/Recording/RecordingOverlaySource.swift:255-256,433-437` | Name both; add the permission row | S | traced |

**P3:** the card-layout editor shows its accessibility fallback as main UI and doubles the pane
(`CardLayoutEditor.swift:156-207`); Move to Applications replaces an existing copy with no version
check (`MoveToApplications.swift:87-90`); permission polling starts a new 100 ms loop on every call
(`OnboardingModel.swift:185-208`); no filename-template preview; "Copied" never reverts; the main
menu has no Services submenu.

## 5. Cross-app projects

These are measured repo-wide over 654 non-test Swift files. Each count is a `grep` that can be
re-run; the pattern is given.

### 5.1 X-1 · One design-token set (P2, M)

**Measured drift**

| Item | Count | Pattern |
|---|---|---|
| Hard-coded SwiftUI font sizes | 74 (against 140 semantic) | `\.system\(size:` |
| Text below 10 pt | 7 sites | size literal < 10 |
| Black/white opacity fills used as chrome | 79 | `(black\|white)\.opacity\(` |
| Corner-radius literals | 86, in 13 distinct values | `cornerRadius` |
| Padding literals | 134, about 20 distinct values | `\.padding\(` |
| Spring parameter sets | 17 distinct across 25 sites | `spring\|snappy\|smooth` |
| Shadows | 19 distinct across 26 sites | `\.shadow\(` |

- The agent (`Kadr/UX/AccessibilityChrome.swift`) and the editor (`EUI/InspectorStyle.swift`,
  `EUI/EditorMotion.swift`) each have their own tokens; `EditorMotion` is a hand copy.
- There are five families of pill and circle buttons (recording bar, card chrome, peek tab, coach
  popover, inspector).
- Worst surfaces: the studio transport and zoom lanes, Quick Access card chrome, the recording bar.
  Settings and the inspector are the cleanest.

**Change**

1. Add a small token file to ControlKit, which both apps already link:
   - Type: `micro` 10, `caption` 11, `body` 12, `title` 13, each with a numeric variant.
   - Radius: 4 / 6 / 8 / 12 / capsule.
   - Space: 2 / 4 / 6 / 8 / 12 / 16.
   - Motion: `hover`, `state`, `layout`, `reduced`.
   - Fill: `hover`, `selected`, `stroke`, `scrim`, each contrast-aware (this replaces the 79
     opacity fills and gives X-3 its hook).
2. Re-point `InspectorMetrics` and `RecordingBarMetrics` at it instead of rewriting them.
3. Raise the seven sub-10 pt sites to `micro` and add a lint rule against smaller literals. Sites:
   `EUI/StudioTransportBar.swift:304`, `Kadr/QuickAccess/QuickAccessPeekTab.swift:56`,
   `Kadr/Recording/RecordingNotchIsland.swift:156`, `EUI/StudioZoomLaneViews.swift:22,71,112`,
   `Packages/SelectionUI/.../RulerLayerGroup.swift:36`. This closes UX-04.

### 5.2 X-2 · One feedback model, and no silent failures (P1 for the list, P2 for the model)

- There are eight feedback mechanisms: `FailurePresenter`, per-card `FeedbackStatus`, 28 `NSAlert`
  sites, SwiftUI alerts, the editor banner, the studio banner and notice, two toasts, and
  `RecordingFailureNotice`. The agent, editor and studio share no type.
- 45 of 132 `catch` blocks log without touching UI; about 18 of those are real user-initiated
  failures.

**X-5a, fix now (Phase 1):**

| Site | What fails silently |
|---|---|
| `EUI/StudioDocumentModel+Close.swift:29` ✔ | The studio edit fails to commit on close. Possible lost work. |
| `Kadr/Recording/RecordingCoordinator+Control.swift:29,60` | Pause or Resume fails; the bar shows nothing. |
| `KadrEditor/EditorWindowController+Export.swift:241` | Share fails; its sibling Pin reports. |
| `Kadr/Onboarding/OnboardingModel.swift:240` | The login-item toggle in onboarding. |
| `Kadr/History/HistoryController.swift:366,435` | History rename; History cannot open (OUT-3). |
| `Kadr/AppDelegate+Termination.swift:57-66` | A failed `kadr://` command. |

**Then (Phase 3):**

- Move the `FeedbackStatus` value type (kind, message, retry) into ControlKit and render it in all
  three apps.
- Write the rule down: a banner for recoverable failures, an alert only to confirm destruction, a
  toast for completion.
- Add a gate to `check-layering.sh`: `logger.error` inside a `catch` in `Kadr/` with no presenter
  call, outside an allow-list.

### 5.3 X-3 · Accessibility settings coverage (P2, M)

| Setting | Coverage |
|---|---|
| Reduce Motion | Good: 23 files; 6 ungated sites of 66, all short fades. |
| Reduce Transparency, Increase Contrast | 5 agent call sites; **0 in the editor** (`EditorMotion`'s properties have no callers). |
| Differentiate Without Colour | **0 references**, against 52 status-colour uses. |

- **Change:** route strokes and fills through the contrast-aware tokens from X-1. Add a non-colour
  cue to each colour-only state: pending cuts, fillers and the active word in the studio; redaction
  review; the notch; on/off toggles in the recording bar.
- **Still owed from docs/15:** a recorded Accessibility Inspector audit for each of the 11
  surfaces, and an XCUITest target (UX-02). This is P1 before an external beta.
- **Interactive views with no accessibility of their own:** `Kadr/Capture/ScrollRegionEditor.swift`
  (CAP-12), `Kadr/StatusItem/StatusItemDropView.swift`, History cells (OUT-8).

### 5.4 X-4 · Localization plumbing (P2 now, P1 before a second language; L)

**Measured**

| Target | Kind | Distinct strings | In a catalog |
|---|---|---|---|
| Kadr | SwiftUI literals | 337 | 253 |
| Kadr | `String(localized:)` | 208 | 113 |
| Kadr + KadrEditor | AppKit titles and alerts | 88 | 18 |
| EditorUI | SwiftUI literals | 276 | 11 |

- No package has a catalog or `defaultLocalization`. About 280 `case .x: "English"` titles in the
  pure packages reach the UI as plain `String`, which SwiftUI shows verbatim.
- Pseudolocalization reaches 51 call sites, about 8% of strings, so the layout tests exercise a
  small subset.
- 16 hand-built plurals, and no use of duration or number formatters (`"%.1f×"` in six places).

**Change**

1. Give EditorUI its own catalog with `bundle: .module`.
2. Return `LocalizedStringResource` from the pure packages' titles (Foundation only, so layering
   still passes).
3. Replace the pseudo-locale helper with a real pseudo-locale in the catalogs, launched with
   `-AppleLanguages`.
4. Fix the hand-built plurals and concatenations (list in the review: `StudioStorageSection.swift:41,52`,
   `TextCaptureReview.swift:122-124`, `QuickAccessPeekTab.swift:9`, `StudioWindowController.swift:272`, …).
5. Add a CI check that a build leaves the catalog unchanged.

### 5.5 X-5 · One vocabulary (P2, S for strings)

| Problem | Examples | Proposed rule |
|---|---|---|
| British and US spelling mixed: 28 "colour" against 4 "color" | "Pick Colour…", "Centre", and "recognises" in the permission prompt every user sees | Pick US (the development language is `en`), or ship `en-GB` |
| One surface, four names | "All-in-One", "capture island", "All-in-One strip", "the HUD" | One name; enforce through a shared constant |
| "Overlay" means cards, recording overlays, the selection surface and all Kadr chrome | "Open in Overlay", "Close All Overlays", "Keystroke overlay" | "Card" for the thing, "Quick Access" for the feature, "overlay" only for on-recording overlays |
| "History" (22) and "library" (11) | Settings ▸ History | "History" everywhere |
| Same action, different label | "Reveal in Finder" / "Show in Finder"; "Got it" / "Got It"; "Install speech model…" / "Download Language Model…"; "System audio" / "System sound"; "Start over" / "Restart" | One each; Title Case for buttons |
| Delete / Remove / Discard / Move to Trash used without a rule | 24 / 25 / 13 / 14 uses | Write the rule: Move to Trash when it goes to the Trash, Discard for an unsaved take, Remove for a reference, Delete only when permanent |
| Copy defects | "See Run `kadr help` in Terminal" with literal backticks (`AutomationConsentSection.swift:18-19`); captions under the wrong control (`GeneralPane.swift:116-123`, `CapturePane.swift:202-203`); "Return saves the hovered card" contradicts docs/03 §2 | Fix in the same sweep |

Menus are already in good order: all 82 titles are Title Case and every ellipsis is a real `…`.

### 5.6 X-6 · Tests where the seams are (P1 for the editor target, M)

- Packages are healthy (test-to-source ratio 0.33–1.19).
- **`KadrEditor/` (2,939 lines) and `HelperTools/` (508) have no test target.** Autosave, export,
  save and rebind, close and quit review, trash and both menus are untested. ED-1 and ED-3 are
  exactly this kind of seam bug.
- **Change:** add `KadrEditorTests` with a menu walk (as docs/17 asked) and open → save → reopen
  against real temp folders.
- **Tests this review found missing:** a static tail through a real `SegmentWriter` (REC-3); a
  killed-writer recovery fixture (REC-4); cancel-then-start on the coordinator (REC-7); a corrupted
  History database (OUT-3); studio failure-action dispatch (STU-2); helper timeout with a
  non-replying service (STU-8); minimum drag size (CAP-3).

### 5.7 X-7 · Project and release hygiene (P1 before the repository is public)

| Item | Evidence | Effort |
|---|---|---|
| Placeholders: security contact, Sparkle feed host and public key, cask version, problem-report URL | `SECURITY.md:22`; `Config/Kadr-Info.plist:31`; `Distribution/kadr.rb:10-11`; `Kadr/Diagnostics/ProblemReport.swift:17-19` | S |
| README is written for contributors: no screenshot, no install section, no feature list, no explanation of the permissions | `README.md` | S–M |
| Nothing tests on macOS 14, the deployment target; several surfaces branch on macOS 26 | `.github/workflows/ci.yml` | S |
| `Scripts/check-dead-api.sh` is wired into neither the Makefile nor CI | — | S |
| `.cursor/hooks/state/*.json` are ignored but still tracked; `_to_delete/` is still in history (the licence-caution purge docs/17 asked for) | `git ls-files .cursor` | S |
| `docs/00-README.md` omits docs 14 and 15 and `AUTOMATION.md`, and marks two docs "Current plan" | — | S |
| Agent and helper carry different speech-permission strings; lint tools are unpinned in CI; no release workflow | `Kadr.xcodeproj/project.pbxproj:720,892` | S |
| Type sizes hidden by file splitting: `StudioDocumentModel` 2,803 lines in 15 files, `EditorDocumentModel` 2,362, `AnnotationCanvasView` 2,150; 29 files within 50 lines of the 500-line cap | — | opportunistic |

## 6. Still open from docs/14 and docs/17

Checked against the code, not the documents. Items not listed here were found fixed.

| ID | What is left | Evidence |
|---|---|---|
| UX-01 | Localization safety net | §5.4 |
| UX-02 | No end-to-end accessibility test or recorded audit | §5.3 |
| UX-03, UX-04 | Contrast and transparency coverage; sub-minimum type | §5.1, §5.3 |
| UX-05 | The layout contract is used by 2 source sites; windows keep their own minimums | `Kadr/UX/UXLayoutContract.swift` |
| UX-10 | Long prose remains in three settings panes | `HistoryPane.swift:32-35`; `OverlayPane.swift:58-61` |
| UX-14 | The island is sized from `fittingSize`, so the widest layout always wins; record setup is one fixed row | `Kadr/Capture/AllInOneHUD.swift:95`; `RecordSetupView.swift:19-31` |
| UX-16 | Compact notch has no Stop or Pause without hover | REC-11 |
| UX-17B/C | Loupe colour not exposed; no visible hint in confirm mode | `HintLayerGroup.swift:112-113` |
| UX-18 | No pointer-free way to focus a card | `Kadr/Commands/` |
| UX-25 | The editor toolbar is a custom row with no overflow, about 764 pt against a 760 pt minimum | `EUI/EditorToolbar.swift:33-89` (device) |
| UX-32–36 | Studio: zoom handles are buttons with no action; crop handles have no keyboard; transcript has no arrow navigation and marks active and selected only by tint; the notice auto-dismisses with no pause | `EUI/StudioZoomLane.swift:240-243`; `StudioTranscriptPanel.swift:304-309` |
| T-DIAG-2/3 | No MetricKit subscriber in the editor; 149 `.info` logs against 16 `.notice`; no `.private` annotations | `Kadr/Diagnostics/MetricKitCollector.swift` |
| T-SH-4 | The Permissions pane's Screen row probably never flips; no Speech Recognition row; default save folder is still Desktop | `Kadr/Settings/PermissionsPane.swift:5` (device) |
| T-CAP-3 | Screen, GIF, Scrolling and Colour discard the saved frontmost app | `Kadr/AppDelegate+Commands.swift:148-167` (device) |
| T-CAP-6 | Four capture failures still only log | `AreaCaptureCoordinator.swift:434,462`; `+OCR.swift:40-42` |
| T-CAP-10 | The HUD's Auto Scroll button raises a modal explainer over a live capture | `ScrollCaptureCoordinator+Auto.swift:38-42` |
| T-CAP-12 | Freeze never includes the cursor; timer menu loses the custom value; toast has no hover pause; save-target menu semantics | `AreaCaptureCoordinator.swift:226`; `AllInOneView.swift:166-172` |
| T-CAP-13 | macOS 15.2+ exclusion relies on `sharingType` alone | `CaptureEngine+RectCapture.swift:191-215` (device) |
| T-OUT-8, T-OUT-10 | Recordings are hashed and copied whole into History; hash file names still leak from Reveal, library-card drags and Pin/Annotate from History | OUT-6 |
| T-REC-7 | Panels that appear mid-take rely on `sharingType` alone | `RecordingCoordinator+Plumbing.swift:55` (device) |
| T-ED-7, T-ED-9 | No window restoration; Open Recent lists only `.kadr` files | `KadrEditor/EditorAppDelegate.swift:284` |
| T-ED-12 | Print, Export Size, context menu, nudge coalescing, Save As format, locked-object feedback | ED-11, ED-12 |
| T-STU-5 | The macOS 26 speech engine has no cancellation handler | `Packages/VisionServices/.../SpeechEngines.swift:153-167` (device) |
| T-STU-9 | Trim export is unguarded | `KadrEditor/TrimWindowController.swift:37,123-140` |
| T-STU-11, T-STU-12 | J is a jump back, not reverse play; no I/O marks; snapping cannot be bypassed; audio panels still modal; no HDR/P3; transcript not virtualised | STU-10, STU-11, STU-15 |
| T-REL-1, T-REL-4, T-REL-8 | No release has been cut; feed host is a placeholder; history purge | §5.7 |

## 7. Device verification, before changing behaviour

These came from reading code. Reproduce each on a real build first; add the rows to docs/12.

| Item | What to try |
|---|---|
| ED-1 | Capture with no default look → Annotate → ⌘S. Does a Save As sheet appear? Then Move to Trash: is the Desktop file still there? |
| OUT-1 | Click Copy on a card, then ⌘V in another app. Then type ⌫. |
| CAP-4 | Area capture from the island over a focused window: are the traffic lights grey in the result? |
| CAP-5 | On macOS 15.2+, fullscreen capture with "Include cursor" on. |
| REC-3 | Record a still desktop with audio off; stop by hotkey after 10 s; check the file's duration. |
| REC-4 | `kill -9` Kadr mid-take; relaunch; is the take recovered and playable? |
| REC-5 | Close the lid mid-take for a minute; check the file and the bar's timer. |
| STU-3 | Zoom the timeline, pause, and drag the playhead away from centre. |
| OUT-2 | Drag a fresh card into Terminal and into Finder; check the save folder and staging after a relaunch. |
| SH-4 | With "Hide icons while capturing" on, capture during a Finder copy. |
| SH-8, T-SH-4 | Dismiss the permission-recovery alert with Later: does the previous app get the keyboard back? Does the Screen row flip after a grant? |
| ED-13, STU-15 | Open a 30,000 px scrolling capture in the editor; open a 30-minute recording in the studio at full timeline zoom. |
| UX-25, SH-11 | Editor at its minimum width; `KadrSlider` in light mode at rest. |
| Visual pass | Screenshots of all 11 surfaces in Light, Dark, Increase Contrast and Reduce Transparency (docs/14 D0). |

## 8. Done well: must not regress

- **Capture:** typed geometry end to end; freeze-then-crop with strict bitmap lifetime; a
  CALayer-only pointer path; non-activating key panels that never return focus to Kadr.
- **Cards and History:** the file-promise architecture; the strict card-key table with undoable
  Trash; the capture/library/external origin model; never-overwrite naming.
- **Recording:** generation-token lifecycle and serialised segment close; stop-travel trimming;
  interruptions that save what was captured and say so; a full Reduce Motion path for the notch.
- **Editor:** snapshot undo with gesture coalescing; redactions burned from pixels before anything
  is drawn; off-main export with an actionable banner; 24 pt screen-space handles at any zoom.
- **Studio:** one composer drives preview and export; snapshot at export start with cleanup on
  every throw; Tidy Speech as a reviewable proposal; a helper that exits when idle.
- **Shell:** windows built on demand and torn down on close, with leak asserts; onboarding's single
  explained exit; shortcut migration and conflict display; quit that finishes a recording first.
- **Idle budget:** no timers anywhere in the agent; every polling loop is scoped to an active
  recording, capture or hovered banner.

## 9. Spec and document changes this plan needs (rule 7)

| Change | Where |
|---|---|
| ⌘C with a selection copies the flattened image *and* the annotations (ED-2) | docs/03 editor, Export |
| Esc during a running scrolling capture stops and stitches, or needs a second press (CAP-2) | docs/03 scrolling capture |
| Minimum drag size for an area selection (CAP-3) | docs/03 §1.1 |
| Hide desktop icons by a cover window, not a Finder restart (SH-4) | docs/03 desktop hygiene; docs/04 decision log |
| Copy and Share in the studio use a fixed preset (STU-6); a Transcribe action (STU-4) | docs/03 studio |
| A Pause/Resume shortcut (REC-11); behaviour on sleep (REC-5) | docs/03 recording |
| History schema v2 with the original path (OUT-6) | docs/04 |
| The glossary in §5.5 | docs/03 preamble, `CONTRIBUTING.md` |
| AVCapture delegate queues named as allowed alongside SCK handler queues | `CLAUDE.md` rule 5 |
| Device rows from §7 | docs/12 |
| Index docs 14, 15, 18 and `AUTOMATION.md`; mark one current plan | `docs/00-README.md` |
