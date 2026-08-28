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
| `capture-area` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor` | Select an area and capture it. With a region, captures it directly with no overlay. |
| `capture-window` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor` | Pick a window and capture it unoccluded. |
| `capture-fullscreen` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor` | Capture every display. |
| `capture-previous-area` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor` | Re-capture the last area, with no overlay. Fails if there is no previous area yet. |
| `capture-text` | `x`,`y`,`w`,`h`, `delay` | Select an area, recognise the text, copy it. Returns the text. |
| `capture-scrolling` | `action`, `x`,`y`,`w`,`h`, `delay`, `cursor` | Capture a scrolling region and stitch it. |
| `pick-color` | — | Freeze the screen and open the loupe as a colour picker. Returns the colour. |

- `action` — `copy`, `save`, `annotate`, `pin` or `overlay`. Omit it to use the
  **Default action** from Settings → General. It applies to this capture only; the
  setting is never changed.
- `x`,`y`,`w`,`h` — a region in **AppKit screen points** (origin bottom-left, the
  coordinates a window's `frame` reports). All four or none: half a rectangle is an
  error, never a guess. `w`/`h` may also be spelled `width`/`height`.
- `delay` — self-timer override in seconds (`timer`, `seconds`). `0` disables it.
- `cursor` — draw the pointer into the capture.

### Recording

| Verb | Parameters | What it does |
|---|---|---|
| `record-screen` | `fps`, `x`,`y`,`w`,`h`, `microphone`, `system-audio` | Start recording the main display. |
| `record-region` | `fps`, `x`,`y`,`w`,`h`, `microphone`, `system-audio` | Select a region, then record it. |
| `stop-recording` | — | Stop and finalise. Returns the `.mp4` path. |

- `fps` — 1–120 (`framerate`, `frame-rate`). Rounded to the nearest encoder preset
  (24 / 30 / 60).
- `microphone`, `system-audio` — booleans (`audio` is an alias for the latter).

`record-screen` returns as soon as it is rolling; the file does not exist until the
user stops. `stop-recording` is what hands back the path.

### Files

| Verb | Parameters | What it does |
|---|---|---|
| `pin` | `path` *(required)* | Pin an image on top of every window. |
| `annotate` | `path` *(required)* | Open an image in the editor. |
| `add-to-history` | `path` *(required)* | Copy a file into the capture library, so it shows up in History. Kadr's editor uses this when you save a `.kadr` project. |
| `close-all-pins` | — | Close every pinned screenshot. |
| `restore-recently-closed` | — | Bring back the last dismissed overlay card. |

`path` may be spelled `filepath` or `file`, and `~` is expanded.

### The rest

| Verb | Parameters | What it does |
|---|---|---|
| `toggle-desktop-icons` | `state` | `on` hides the icons, `off` shows them, `toggle` flips (default). |
| `freeze-screen` | — | Freeze the displays so moving UI can be inspected. |
| `open-history` | — | Open the capture library. |
| `open-settings` | `tab` | `general`, `overlay`, `capture`, `recording`, `history`, `shortcuts`, `updates`, `advanced`. |
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
| `open-annotate`, `annotate-file` | `annotate` |
| `self-timer` | `capture-area` (the delay comes from Settings unless you pass `delay`) |
| `all-in-one` | `capture-area` |
| `record-gif` | `record-screen` (export the GIF from the overlay card) |
| `stop-capture` | `stop-recording` |
| `toggle-desktop`, `hide-desktop-icons` | `toggle-desktop-icons` |
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
**Capture Screen**, **Capture Text**, **Start Recording**, **Stop Recording**,
**Pin Image**, **Set Desktop Icons** and **Open History**. The capture actions return a
file the next action can consume; **Capture Text** returns a string. Cancelling a
capture fails the shortcut, so an "if" block can handle it.
