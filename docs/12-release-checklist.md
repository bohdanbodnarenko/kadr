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

      log stream --predicate 'subsystem == "app.kadr"' --info | grep geometry-probe

      If `content` stays near the origin while `screen` moves, `contentRect` is surface
      space: switch both consumers to `.screenRect` (with a 14.0 fallback) and rebuild the
      `WindowSpaceTests` fixtures around the real answer. If both move together, the
      current reading is right and the probe can be deleted.
