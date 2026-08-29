## What this changes

<!-- One paragraph: what a user can now do that they could not before, or what stopped
     being wrong. Link the milestone (docs/06, docs/09) and the spec section (docs/03). -->

## Why this way

<!-- The decision worth writing down: what else was considered, and what made this the
     one. If a spec in docs/03 was ambiguous, say which reading was taken — CLAUDE.md
     rule 7 asks for the interpretation here rather than invented UI. -->

## Checks

- [ ] `swiftlint lint --strict` and `swiftformat --lint .` are clean.
- [ ] `Scripts/check-layering.sh` and `Scripts/check-size.sh` pass.
- [ ] Every touched package's `swift test` passes, and the new behaviour has tests —
      pure maths table-driven, renderers golden-imaged, state machines exhaustive.
- [ ] Anything with a PRD §8 budget kept its `os_signpost`, and gained one if it is new.
- [ ] Nothing landed in the agent process that the editor or a helper could do instead
      (CLAUDE.md rule 2); agent idle stays under 30 MB with no timers.

## Licence hygiene

Kadr is MIT. QuickRecorder and Capso are AGPL, and Screendrop's `Engine/` is derived from
tldraw's non-permissive source. All three are read-only reference: their *behaviour* can
be studied and reimplemented, their code cannot be copied, adapted, translated or
machine-translated into this repository.

- [ ] This PR contains no code derived from Screendrop's `Engine/` or other
      non-permissive sources.
- [ ] Any new dependency is justified against docs/04 §12 and its licence is compatible
      with MIT.

## Zero network

CLAUDE.md rule 1: no networking anywhere outside the Sparkle update integration. There are
no upload or share-by-URL features — sharing is drag-and-drop and `NSSharingServicePicker`.

**Nothing the user made ever leaves the machine.** No capture, recording, transcript or
audio is uploaded, for any reason, including to a system API that would do the uploading —
`requiresOnDeviceRecognition` and its equivalents are set unconditionally, never
conditionally on a fallback.

There is one narrow exception, and adding to it needs the same argument this one made.
`SpeechModelInstaller` downloads Apple's on-device speech model, on these terms:

- **A person pressed a button that says so.** No feature path and no launch path calls it.
- **Nothing waits for it.** Every feature works with whatever is installed and fails cleanly
  when nothing is. Offline, the app behaves exactly as it would if the installer did not
  exist.
- **It is cancellable**, and cancelling leaves everything as it was.
- **It fetches a model, not a user's data.** The direction matters: the model comes here so
  the recording does not have to go there.

- [ ] This PR adds no networking beyond Sparkle and that exception, and uploads nothing the
      user made.
- [ ] Any system API that can fetch on Kadr's behalf is called only from an explicit user
      action, never blocks a feature, and is cancellable.
