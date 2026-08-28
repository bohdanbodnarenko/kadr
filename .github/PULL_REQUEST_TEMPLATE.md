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
This includes system APIs that reach the network on Kadr's behalf: a speech, translation or
model-download call that leaves the machine is a network call Kadr made.

- [ ] This PR adds no networking, and no system API that fetches or uploads on Kadr's behalf.
