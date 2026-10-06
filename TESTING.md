# Testing Kadr

Thank you for dogfooding Kadr. This page is everything you need: how to install it, what
it will ask permission for and why, how to tell us when something goes wrong, and what we
already know is broken.

Kadr never sends your captures anywhere. The only thing it does on the network is check
for updates.

## 1. Install

1. Open the `Kadr-0.9.0.dmg` you were sent.
2. **Drag Kadr into Applications, then eject the disk image — before you open Kadr.**
   Launching it straight from the disk image (or from Downloads) runs it from a temporary
   location macOS makes up. Permissions, launch at login, the `kadr` command and updates
   all attach to that location and break when it goes away.
3. Open Kadr from Applications. It lives in the **menu bar**, not the Dock: look for its
   icon at the top right of the screen. If you do open it from the disk image, Kadr offers
   to move itself to Applications and reopen.

If you had a build from `make install` before, the first signed build will ask for Screen
Recording, Accessibility and Input Monitoring **once more**. That is macOS noticing a
different signature, not a bug.

## 2. Permissions, and why each is needed

Kadr asks for each one the first time a feature needs it, not all at once.

| Permission | Needed for | Without it |
|---|---|---|
| **Screen Recording** | Every screenshot and recording. | Nothing can be captured. After granting it, Kadr needs to quit and reopen — it offers to. |
| **Accessibility** | Auto-scroll in scrolling capture, and key overlays in recordings (to read shortcuts, never ordinary typing). | Those two features are off; everything else works. |
| **Input Monitoring** | Showing keystrokes in a recording. | Keystroke overlays are off. |
| **Microphone** | Recording your voice. | Recordings have system audio only. |
| **Camera** | The camera bubble in a recording. | No camera bubble. |
| **Speech Recognition** | Captions, the teleprompter's follow-along and filler-word removal in the studio. Runs on your Mac. | Those features are off. |

**On macOS 15 and later**, macOS asks roughly once a month whether Kadr may keep
recording the screen. Choose **Allow** — that prompt comes from macOS, not from Kadr.

## 3. Updates

Settings ▸ Updates ▸ **Receive beta builds** is on for testers; leave it on. Builds come
weekly, and hotfixes within a day for anything serious. Check by hand with Settings ▸
Updates ▸ **Check Now**, or **Kadr ▸ Check for Updates…** while a Kadr window is open. When
a background check finds a build while you are busy, Kadr doesn't interrupt: the menu-bar
menu shows **Update to 0.9.x…** until you get to it. The version and build (for example
`0.9.0 (512 · abc1234)`) are in Settings ▸ Updates, with a Copy button.

## 4. Reporting a problem

**Help ▸ Report a Problem…** (also in the menu-bar menu — hold ⌥ to see it) does two things:

1. It saves a **diagnostics zip** and shows it in Finder. The zip contains Kadr's logs from
   the last day, any crash or hang reports, and a `system.json` describing your Mac
   (macOS version, displays, which permissions are granted, non-default settings with file
   paths shortened to `~`). It contains **no captures, no recordings and no file
   contents**. Open it and look if you like.
2. It opens a bug form in your browser with the version fields filled in. Kadr itself sends
   nothing; you attach the zip.

**Help ▸ Export Diagnostics…** makes just the zip, if you are reporting some other way.

### What makes a good report

- **One problem per report.**
- **Steps from a known starting point**: "with Safari in front I pressed ⇧⌘2, chose Window,
  clicked the Safari window" beats "window capture is broken".
- **What you expected, and what happened instead.**
- **A short screen recording** of it happening. Kadr can make one; if Kadr is what is
  broken, use ⇧⌘5.
- **The diagnostics zip**, made soon after it happened — the logs only go back a day.
- **Anything unusual about your setup**: several displays, a display arranged above the
  main one, an Intel Mac, VoiceOver, another screenshot tool running.

If Kadr crashed, macOS may show its own "quit unexpectedly" window. Click **Report…** there
too if you like, but the diagnostics zip is what reaches us.

### More detailed logs (optional)

macOS normally throws away Kadr's informational log messages after a short while. If we
ask you to reproduce something, this keeps them (it needs your password; undo it with the
second command when you are done):

```sh
sudo log config --subsystem com.bohdanbodnarenko.kadr --mode "level:info,persist:info"
sudo log config --subsystem com.bohdanbodnarenko.kadr --reset
```

## 5. Known issues

We know about these; you don't need to report them unless something is worse than
described.

**Capture**
- With several displays, keys pressed in the selection overlay can go to the wrong display.
- Capture Screen from the default shortcut plays no sound and skips your after-capture actions.
- In the island's Screen menu, "Active display" captures all displays.
- Some capture failures show nothing on screen; the capture just doesn't happen.
- Large captures can pause Kadr briefly after the shot.
- Capture Text with W (window) produces an image and replaces the clipboard with it.
- The self-timer counts down twice.
- Scrolling capture controls are rough.
- On macOS 15.2 and later, a card or pin may appear in a fullscreen capture.

**Cards, pins and History**
- Deleting a card cannot be undone, and Trash is very close to Hide.
- One very long recording can push everything else out of History.
- A pin set to click-through is hard to get back.
- Some files leave History with hash-like names.
- Save As on some cards writes an extension that doesn't match the file.
- `kadr://` links and the `kadr` command run without asking first.

**Recording**
- Starting a new recording while the last one is still saving can damage the last one; there is no "Saving…" state yet.
- Recording an area makes Kadr the front app, so the app you are recording loses focus.
- The teleprompter window may appear in the recording.
- Some permission or device problems at start are reported late or unclearly.
- Very long takes (20 minutes and more) are not well tested.

**Editor**
- Settings "Lock objects…" and "Object shadows…" have no effect.
- Dropping images onto the canvas doesn't work, and ⌘V with an image is disabled.
- Quitting with unsaved edits doesn't ask, and windows aren't restored.
- ⌘S, ⌘P and ⇧⌘C in a Studio or Help window act on a hidden annotation window.
- Files opened from Finder are copied and edited as a copy.
- ⌘\` is "Decrease Tool Size", not "cycle windows".

**Studio**
- The export frame-rate option is ignored.
- Copy and Share renders can't be cancelled.
- Cancelling transcription or the speech-model download doesn't stop the work.
- "Remove Filler Words" can also remove silent on-screen demonstrations.
- GIF export can be clipped or reduced without saying so.
- Delete removes the clip under the playhead, not the one you selected.
- Some default export settings make files that don't play everywhere (for example H.264 at 5K).

**App**
- Speech Recognition isn't listed in Settings ▸ Permissions; if it is denied, the
  teleprompter scrolls at a steady rate instead of following your voice.
- The editor's Help menu has no search field yet.

## 6. What not to test yet

- Localization: Kadr is English-only for now.
- The external-beta polish items (accessibility audits, the full display matrix). Tell us
  if something blocks you, but these are scheduled after internal testing.

## 7. Starting over

To reset Kadr to a first launch — settings, History, studio sessions, permissions, the
`kadr` link, and desktop icons if a crash hid them — quit Kadr and run:

```sh
Scripts/uninstall.sh            # asks first; --yes to skip, --remove-app to delete the app too
```

or, from inside the app, Settings ▸ Advanced ▸ **Remove All Kadr Data…** (everything
except permissions, which only the script can reset). Captures you saved to your own
folders are never touched.
