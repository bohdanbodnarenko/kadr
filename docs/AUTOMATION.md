# Automating Kadr

Kadr exposes one command vocabulary through three frontends (docs/03 §8.4):

| Frontend | How | Gets a result back |
|---|---|---|
| URL scheme | `open "kadr://capture-area?action=copy"` | no |
| CLI | `kadr capture-area --action copy` | yes — stdout + exit code |
| Shortcuts | the actions under *Kadr* in Shortcuts.app | yes — a file or text |

All three parse the same verbs and the same parameters through
`Packages/AutomationKit`, so anything documented here works in all of them.

Nothing about automation talks to a network. The CLI reaches the agent over a local
Mach port (`CFMessagePort`), and every ScreenCaptureKit call stays in the agent, which
is the process the Screen Recording grant belongs to (docs/04 §1).

---

## Installing the CLI

**Settings → Advanced → Command Line Tool → Install.**

It symlinks `Kadr.app/Contents/Helpers/kadr` into `/usr/local/bin` when that is
writable, and into `~/.local/bin` otherwise. Because it is a symlink into the app
bundle, updating Kadr updates the tool.

```sh
kadr help                 # the verb list
kadr capture-area --json  # {"paths":["/…/Kadr-2026-08-28-14-02-11.png"],"status":"ok"}
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | failed — `message` says why |
| 2 | the user cancelled (pressed Escape, closed the picker) |
| 3 | the verb is understood but unavailable in this build |
| 64 | the command line did not parse (`EX_USAGE`) |

Cancel is deliberately not 1: a script wants to tell "the user changed their mind"
apart from "something broke".

### CLI-only flags

| Flag | Effect |
|---|---|
| `--json` | one JSON object on stdout: `{"status","paths","text","message"}` |
| `--no-wait` | deliver the command and exit 0 without waiting for the result |
| `--timeout <seconds>` | how long to wait. Defaults to 120 s for capture verbs, 10 s for the rest |

Values may be written `--name value` or `--name=value`. Boolean parameters work as bare
flags (`--cursor`) and can be negated (`--no-cursor`).

---

## Verbs

Parameters not listed for a verb are a **parse error**, not a silent no-op — a script
that misspells `action` is told so rather than quietly capturing with the wrong policy.

### Capture

| Verb | Parameters | What it does |
|---|---|---|
| `capture-area` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display` | Select an area and capture it. With a region, captures it directly with no overlay. |
| `capture-window` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display` | Pick a window and capture it unoccluded. |
| `capture-fullscreen` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display` | Capture every display, or one display when `display=` is set. |
| `capture-previous-area` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display` | Re-capture the last area, with no overlay. Fails if there is no previous area yet. |
| `capture-text` | `x`,`y`,`w`,`h`, `delay`, `linebreaks`, `display`, `path` | Select an area, recognise the text, copy it. With `path`/`filepath`, OCR that image file instead. Returns the text. |
| `capture-scrolling` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display`, `start`, `autoscroll` | Capture a scrolling region and stitch it. With a region and `start=true` (the default), frame capture begins immediately; `start=false` shows the selection overlay first. `autoscroll` overrides Settings → Capture for this run. |
| `all-in-one` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display` | Open the All-in-One HUD. With a region, captures that rectangle instead. |
| `self-timer` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor`, `display` | Count down, then open area capture so hover menus can be staged. |
| `pick-color` | — | Freeze the screen and open the loupe as a colour picker. Returns the colour. |

- `action` — `copy`, `save`, `annotate`, `pin` or `overlay`. Omit it to use the
  **Default action** from Settings → General. It applies to this capture only; the
  setting is never changed.
- `x`,`y`,`w`,`h` — a region in **AppKit screen points** (origin bottom-left, the
  coordinates a window's `frame` reports). All four or none: half a rectangle is an
  error, never a guess. `w`/`h` may also be spelled `width`/`height`. Without
  `display`, the origin is the global screen origin (the primary display's
  bottom-left). With `display=`, `(0,0)` is the bottom-left of **that** display,
  matching CleanShot.
- `display` — 1-based display index. `1` is the primary display (the screen with
  the menu bar). An index this Mac does not have is a runtime error, not a parse
  error. On `capture-fullscreen`, `display=` captures that one display rather than
  every display.
- `delay` — self-timer override in seconds (`timer`, `seconds`). `0` disables it.
- `cursor` — draw the pointer into the capture.
- `linebreaks` — `true` keeps recognised line breaks, `false` folds them to spaces. Omit it to use Settings → Capture. Also spelled `line-breaks`.
- `start` — on `capture-scrolling` only: with a region, `true` (default) begins frame capture immediately; `false` shows the selection overlay first.
- `autoscroll` — on `capture-scrolling` only: `true` lets Kadr synthesize scroll events for this run; `false` leaves scrolling to you. Omit it to use Settings → Capture.
- `path` — on `capture-text` only: OCR an existing image (`filepath`, `file`). `~` is expanded. When `path` is set, `x,y,w,h` and `display` are ignored — the file is the source.

### Recording

| Verb | Parameters | What it does |
|---|---|---|
| `record-screen` | `fps`, `x`,`y`,`w`,`h`, `microphone`, `system-audio`, `display` | Start recording the main display, or the display `display=` names. |
| `record-region` | `fps`, `x`,`y`,`w`,`h`, `microphone`, `system-audio`, `display` | Select a region, then record it. With a region, starts immediately. |
| `record-gif` | `fps`, `x`,`y`,`w`,`h`, `microphone`, `system-audio`, `display` | Record a region, then encode a GIF when the recording stops. |
| `stop-recording` | — | Stop and finalise. Returns the `.mp4` path. |

- `fps` — 1–120 (`framerate`, `frame-rate`). Rounded to the nearest encoder preset
  (24 / 30 / 60).
- `microphone`, `system-audio` — booleans (`audio` is an alias for the latter).

`record-screen` returns as soon as it is rolling; the file does not exist until the
user stops. `stop-recording` is what hands back the path.

### Files

| Verb | Parameters | What it does |
|---|---|---|
| `pin` | `path` *(optional)* | Pin an image on top of every window. Without `path`, Kadr asks for a file. |
| `annotate` | `path` *(required)* | Open an image in the editor. |
| `add-to-history` | `path` *(required)* | Copy a file into the capture library, so it shows up in History. Kadr's editor uses this when you save a `.kadr` project. |
| `add-quick-access-overlay` | `path` *(required)* | Show an existing file as a Quick Access card. |
| `open-from-clipboard` | — | Open the clipboard image, movie, or file as a Quick Access card. |
| `close-all-pins` | — | Close every pinned screenshot. |
| `hide-pins` | — | Hide or show every pinned screenshot. |
| `close-all-overlays` | — | Dismiss every Quick Access card without deleting the files. |
| `save-all-overlays` | — | Save (and dismiss) every Quick Access card. |
| `restore-recently-closed` | — | Bring back the last dismissed overlay card. |
| `hide-overlays` | — | Hide overlay cards so they do not appear in the next capture. |

`path` may be spelled `filepath` or `file`, and `~` is expanded.

### The rest

| Verb | Parameters | What it does |
|---|---|---|
| `toggle-desktop-icons` | `state` | `on` hides the icons, `off` shows them, `toggle` flips (default). |
| `freeze-screen` | — | Freeze the displays so moving UI can be inspected. |
| `open-history` | — | Open the capture library. |
| `open-settings` | `tab` | `general`, `overlay`, `capture`, `recording`, `history`, `shortcuts`, `updates`, `advanced`. CleanShot spellings `wallpaper`/`screenshots`/`annotate` land on Capture, `quickaccess` on Overlay, `about` on Updates. |
| `version` | — | The running agent's version. |

---

## CleanShot verb aliases

Scripts written against CleanShot X keep working: replace `cleanshot://` with `kadr://`
(or drop the scheme entirely for the CLI). These spellings are accepted:

| You wrote | Kadr runs |
|---|---|
| `scrolling-capture`, `capture-scrolling-area` | `capture-scrolling` |
| `capture-screen`, `capture-display`, `capture-fullscreen-all` | `capture-fullscreen` |
| `ocr`, `capture-ocr` | `capture-text` |
| `pick-colour`, `color-picker` | `pick-color` |
| `capture-previous`, `capture-area-previous` | `capture-previous-area` |
| `add-floating-screenshot`, `float` | `pin` |
| `close-all-floating-screenshots`, `close-floating-screenshots` | `close-all-pins` |
| `hide-floating-screenshots`, `toggle-floating-screenshots` | `hide-pins` |
| `open-annotate`, `annotate-file` | `annotate` |
| `add-overlay` | `add-quick-access-overlay` |
| `open-from-pasteboard` | `open-from-clipboard` |
| `save-all` | `save-all-overlays` |
| `hide-quick-access-overlay` | `hide-overlays` |
| `stop-capture` | `stop-recording` |
| `toggle-desktop` | `toggle-desktop-icons` |
| `hide-desktop-icons` | `toggle-desktop-icons --state on` |
| `show-desktop-icons` | `toggle-desktop-icons --state off` |
| `open-preferences` | `open-settings` |
| `restore-recently-closed-window` | `restore-recently-closed` |

Verb names are matched case-insensitively.

**Not supported.** CleanShot verbs with no Kadr equivalent are rejected with an
"unknown command" error rather than being pointed at something that does a different
thing: `open-desktop`, `open-cloud`, `open-uploads`, and anything to do with uploading —
Kadr has no upload surface at all, by design (docs/02 §4).

---

## Recipes

**Raycast script command** — capture an area and copy it:

```bash
#!/bin/bash
# @raycast.title Capture Area
# @raycast.mode silent
kadr capture-area --action copy
```

**Capture a fixed region every morning** (region in screen points):

```sh
kadr capture-area --x 0 --y 0 --w 1440 --h 900 --action save --json
```

**Grab the text out of a dialog and pipe it somewhere:**

```sh
kadr capture-text | pbcopy
```

**Read a colour off the screen:**

```sh
kadr pick-color        # "#1D6FE0", or "#1D6FE0  4.72:1 · Lc 71" if you compared one
```

On the picker overlay: `F` cycles HEX / RGB / HSL / OKLCH, `X` samples a second colour to
measure contrast against, Return takes the colour, Escape cancels.

**Record for thirty seconds:**

```sh
kadr record-screen --fps 30 && sleep 30 && kadr stop-recording
```

**Handle cancellation in a script:**

```sh
if path=$(kadr capture-area); then
    echo "captured $path"
elif [ $? -eq 2 ]; then
    echo "user cancelled"
else
    echo "failed" >&2
fi
```

## Shortcuts

The Shortcuts actions wrap the same commands: **Capture Area**, **Capture Window**,
**Capture Screen**, **Capture Text**, **All-in-One**, **Start Recording**, **Stop Recording**,
**Pin Image**, **Set Desktop Icons** and **Open History**. The capture actions return a
file the next action can consume; **Capture Text** returns a string. Cancelling a
capture fails the shortcut, so an "if" block can handle it.
