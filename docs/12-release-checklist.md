# Release checklist

Everything in docs 07, 10 and 11 is static analysis. **No finding in any of them was made
by running Kadr**, because no reviewer in those threads could — which makes the real-device
pass the largest remaining unknown before v1.0, not the smallest (docs/11 S3.1).

Most of what those reviews found would have taken a human ten minutes with a screen
recorder and would never have been found by reading. The mirrored cursor is the clearest
case: it was invisible in 1,688 passing tests and would have been obvious in one recording.

Run this before every release. Tick the box or write down what happened — an unticked box
is a release note, not a failure.

---

## 0. Smoke script (every build, about 15 minutes)

From docs/17 §7.3. Every step must pass before a build goes to testers; this runs before
the longer sections below, which are per release.

1. **Fresh install:** run `Scripts/uninstall.sh`, install the DMG, move the app to
   /Applications, launch. Onboarding → grant Screen Recording → relaunch → practice capture.
   - [ ] passes
2. **Capture from the island (⇧⌘2):** area, window and screen captures; after each one,
   **type into the previous app without clicking** (T-CAP-3).
   - [ ] keystrokes reach the previous app every time
3. **Card:** drag the card into Finder and into Slack/Mail (check the name); Copy, Save,
   Annotate, then Delete and **Undo**; with the pointer resting on a card, type ⌫ into
   another app — nothing must happen (T-OUT-1).
   - [ ] passes
4. **Editor:** add an arrow and text (⌘Return and Esc both keep the text); ⌘S twice (one
   file, Finder not activated); close, reopen from the card — the edits are there; ⌘M works.
   - [ ] passes
5. **Capture Text and Colour pick by click.**
   - [ ] passes
6. **Recording:** record 30 s with the mic; Pause 10 s, Resume, Stop — the file is about
   20 s and gapless (T-REC-1); open it in the studio, cut one clip, export MP4 at 30 fps and
   check the fps (T-STU-3); export again — it reuses the file.
   - [ ] passes
7. **Automation:** `open "kadr://capture-fullscreen?action=copy"` asks for consent once
   T-OUT-12 lands.
   - [ ] passes
8. **Diagnostics:** Help ▸ Report a Problem… produces a zip containing logs and `system.json`.
   - [ ] passes
9. **Updates:** Check for Updates… finds the next build on the beta channel.
   - [ ] passes
10. **Idle budgets:** `make perf` on the release build — idle RSS below 30 MB, 0 % CPU over 60 s.
   - [ ] passes

---

## 1. The flagship, end to end

The definition of done from docs/11, as a script you can actually follow.

1. Grant Accessibility. Record a **10-minute** studio session on a **Retina** display.
2. During it: click a dozen times, type `⌘⇧4`, pause once and resume, drag a window.
3. Open it in the studio. Make a cut and a speed change. Export.

Then check the exported file:

- [ ] The cursor is there, **full size**, and its tip is on what it was pointing at.
      (Half-size means `manifest.scale` is not reaching the composer — docs/11 S0.5.)
- [ ] **One** ripple per click, in the right place, at the right moment.
      (Two means both rungs of the telemetry ladder are installed — S0.2.)
- [ ] The pointer path is smooth, not zig-zagging.
      (Alternating means one rung is mirrored — C1.)
- [ ] Captions and ripples look consistent in size after a reframe.
- [ ] The camera bubble is lip-synced.
- [ ] "Show everything" shows everything — no bar on one side only, nothing cropped.
- [ ] The exported length matches the recording minus what was cut.

## 2. The lifecycle races

All three are ordinary user actions inside windows the user cannot see (docs/11 S0.3).

- [ ] **Pause, then Stop within a second.** The studio timeline is the length of the
      footage, and the playhead cannot scrub past the end.
- [ ] **Start, then Escape/Stop immediately.** No phantom: the menu-bar timer stops, the
      desktop icons come back, and no session directory is left behind.
- [ ] **Start, then quit the app during setup.** Nothing left in Application Support.
- [ ] **Export, then ⌘Q.** Prompted; on "Quit Anyway" no partial file survives at the
      destination.
- [ ] **Export, then close the window.** Same, via the window's own prompt.
- [ ] **Export, then Cancel.** The partial file is gone and no failure is reported.
- [ ] **Export the same edit twice.** The second is instant and says so (docs/11 S2).

## 3. The device matrix

Hardware and OS (docs/11 S3.1):

- [ ] Apple Silicon
- [ ] Intel
- [ ] macOS 14 (the floor)
- [ ] macOS 15
- [ ] macOS 26
- [ ] Overlapping windows on a light wallpaper, macOS 14: window and display captures still show drop shadows (docs/16 CAP-11). Verify.

Displays — this is where the coordinate bugs live:

- [ ] Single Retina display
- [ ] Single 1× display
- [ ] Mixed-DPI dual display, recording on each
- [ ] **A second display arranged *above* the primary.** Negative y in CG space, which is
      the arrangement that silently dropped samples before C1.
- [ ] A second display arranged to the left. Negative x.
- [ ] Hot-unplug a display mid-capture

Conditions:

- [ ] Sleep/wake during a recording
- [ ] A 60-minute recording. Watch the agent's memory at the moment Stop is pressed —
      finalising the telemetry journal is the spike (docs/11 S2).
- [ ] A 5K capture
- [ ] A full disk during export
- [ ] Permission denied → granted → **revoked mid-use**
- [ ] HDR recording with click halos on. The halos are deliberately not baked; the picture
      must be untouched (docs/11 S0.5).

## 4. The gates

Green on a clean checkout:

- [ ] `make lint`
- [ ] `make test`
- [ ] `make check` — layering, zero-network, dead API
- [ ] `make size-gate` — archives and measures the DMG. **Not** `make check-size`, which
      measures a build product and can only overestimate.
- [ ] `make perf`

## 5. Accessibility and first run

Not yet reviewed by anyone (docs/11 S3.4):

- [ ] VoiceOver over the editor and the studio
- [ ] The timeline is fully keyboard-operable
- [ ] Reduce Motion is honoured by the zoom preview
- [ ] The new U- and R-sprint strings are in the String Catalogs
- [ ] First run of the *studio* specifically — the onboarding predates it

## 6. The one open question

`SCStreamFrameInfo.contentRect` is documented by Apple as the content's rect *within the
frame*, and Kadr treats it as a rect on screen. If Apple is right, window-recording clicks
are dropped by `MovingWindowConverter`'s `contains` check and the survivors map wrongly.
This cannot be settled by reading — `WindowSpaceTests` asserts the semantics the code
intends, so it agrees with the code either way.

- [ ] Record a window. Drag it from one side of the display to the other. Then:

      log stream --predicate 'subsystem == "app.kadr.Kadr"' --info | grep geometry-probe

      If `content` stays near the origin while `screen` moves, `contentRect` is surface
      space: switch both consumers to `.screenRect` (with a 14.0 fallback) and rebuild the
      `WindowSpaceTests` fixtures around the real answer. If both move together, the
      current reading is right and the probe can be deleted.

      The subsystem is `app.kadr.Kadr` (the old `app.kadr` predicate matched nothing).
      Testers on release builds need the geometry probe switched on at runtime (docs/17
      T-DIAG-3) to answer this.

## 7. Device verification for internal testing

From docs/17 §8. Each row can only be settled on a real Mac, and each one decides a fix
there.

**Screen-capture exclusion**
- [ ] **`sharingType = .none` on macOS 15.2+ and 26.** Take two fullscreen captures in a row
  with a card and a pin visible. Do they appear? (T-CAP-13)
- [ ] **Teleprompter in a display recording.** Is the script panel in the file? (T-REC-7)

**Focus and keyboard routing**
- [ ] **Island focus return.** After an island capture, does the next keystroke reach the
  previous app? (T-CAP-3)
- [ ] **Multi-display overlay.** Press F with the pointer on the second display before
  clicking. (T-CAP-2)
- [ ] **Area recording focus.** Is the target app active when the take starts? (T-REC-6)

**Recording**
- [ ] **Pause/Resume.** Pause 10 s: is the file length equal to the recorded time? (T-REC-1)
- [ ] **Sleep and stream death.** A 20-minute hands-off take with the display-sleep timeout
  at 10 minutes. Does the display sleep, and does the stream die? (T-REC-10)
- [ ] **Hotkey conflicts.** Does Carbon registration report conflicts with other apps on 15
  and 26? (T-SH-7)

**Speech**
- [ ] **Fillers.** Do Apple's recognisers emit "um"/"uh"? (T-STU-6)
- [ ] **Long audio.** Does on-device file recognition finish a 30-minute track on macOS 14
  and 15? (T-STU-5, T-STU-6)
- [ ] **Return key.** Does Return in the studio reach the Tidy "Apply" default button? (T-STU-6)

**Export**
- [ ] **H.264 at 5K.** Does export succeed or fail? (T-STU-10)
- [ ] **Colour.** Do exported colours match the preview in QuickTime? (T-STU-12)

**Editor**
- [ ] **Print.** What order do the pages of a tall capture print in? (T-ED-12)
- [ ] **Perspective.** Does the live perspective preview match the export? (ED-4)

**Card saves**
- [ ] **Save As extension.** Save As on an HEIC card: extension and bytes. (T-OUT-11)

**First run and install**
- [ ] **First-run permission.** How many dialogs appear on first Screen Recording use? (T-SH-4)
- [ ] **Default save folder.** Does the first save to `~/Desktop` prompt, and does
  `~/Pictures/Kadr`? (T-SH-4)
- [ ] **Updates.** Does the Sparkle update window from the LSUIElement agent come to the
  front, and does it survive the 120 s backstop? (T-REL-4)
- [ ] **TCC across signing change.** From a `make install` build to a Developer ID build:
  which grants re-prompt? (T-REL-1)

**Open question**
- [ ] **§6 `contentRect`.** Now possible with the runtime geometry-probe toggle (T-DIAG-3).

## 8. Device verification for the polish review

From docs/18 §7, plus the device-only items the Phase 1–3 fixes left open. Reproduce each
on a real build; a failure reopens the item named in brackets.

**Editor**
- [ ] **In-place hand-off.** Capture with no default look → Annotate → ⌘S. No Save As sheet;
  the file beside the original changes. Then Move to Trash: the Desktop file goes. (ED-1)
- [ ] **Copy after drawing.** Draw an arrow, press Copy, paste into Slack: the image arrives.
  (ED-2)
- [ ] **Proxy drag.** After a save with a blur, drag the title-bar proxy into Mail: the
  flattened image goes, not the `.kadr`. (ED-3)
- [ ] **Tall captures.** Open a 30,000 px scrolling capture; export it. (ED-13)

**Capture**
- [ ] **W on the area overlay.** Windows highlight and a click captures. (CAP-1)
- [ ] **Esc while scrolling.** Esc during a scrolling capture stitches instead of discarding.
  (CAP-2)
- [ ] **Island captures.** Area capture from the island over a focused window: are the
  traffic lights coloured in the result? (CAP-4)
- [ ] **Cursor on 15.2+.** Fullscreen capture with "Include cursor" on macOS 15.2–15.x. (CAP-5)

**Cards and History**
- [ ] **Card focus.** Click Copy on a card, then ⌘V in another app; then type ⌫ with the
  pointer elsewhere. (OUT-1)
- [ ] **Drag-out.** Drag a fresh card into Terminal and into Finder; check the save folder
  and staging after a relaunch. (OUT-2)

**Recording**
- [ ] **Still ending.** Record a still desktop with audio off; stop by hotkey after 10 s.
  The file is 10 s long. (REC-3)
- [ ] **Crash recovery.** `kill -9` Kadr mid-take; relaunch. Is the take recovered and
  playable? If not, it is reported once with Show in Finder. (REC-4)
- [ ] **Sleep.** Close the lid mid-take for a minute: the take is paused and says so on
  wake. (REC-5)
- [ ] **Studio scrubbing.** Zoom the timeline, pause, drag the playhead away from centre:
  the view does not jump back. (STU-3)

**Shell**
- [ ] **Desktop cover.** With "Hide icons while capturing" on, capture during a Finder copy:
  no Finder restart, icons hidden, wallpaper right. Check its RAM with the icons left
  hidden. (SH-4)
- [ ] **Permission alert focus.** Dismiss the permission-recovery alert with Later: the
  previous app gets the keyboard back. Does the Screen row flip after a grant? (SH-8,
  T-SH-4)
- [ ] **Slider and toolbar.** Editor at its minimum width; `KadrSlider` in light mode at
  rest and with Increase Contrast. (UX-25, SH-11)
- [ ] **Studio length.** A 30-minute recording at full timeline zoom. (STU-15)

**Visual pass**
- [ ] Screenshots of all 11 surfaces in Light, Dark, Increase Contrast and Reduce
  Transparency (docs/14 D0).
