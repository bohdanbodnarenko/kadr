# UX screenshot fixtures

D0 harness notes for `docs/14-ux-ui-excellence-plan.md`. Capture these in a
release-like agent and editor build before visual PRs.

## Launch arguments

    /Applications/Kadr.app/Contents/MacOS/Kadr -KadrPseudolocalize
    /Applications/Kadr.app/Contents/MacOS/Kadr -KadrPseudolocalize2x
    /Applications/Kadr.app/Contents/MacOS/Kadr -KadrRTL

## Matrix

For each major surface, save minimum / regular / large widths at 1× and 2×:

- Onboarding (welcome, permissions, defaults)
- Settings (each pane, sidebar shown and hidden, Learn More popover)
- All-in-One and Record setup HUDs (including save-target and recording-audio)
- Camera/microphone Allow · Open Settings · Use Without popover
- Recording island, notch collapsed/expanded, pre-roll
- Quick Access cards at 140 pt and default width
- History empty, loading, populated, search
- Editor tools, crop, inspector, export progress, Help
- Studio with and without transcript, crop, export

Also capture `-KadrPseudolocalize` and `-KadrPseudolocalize2x` at the declared
minimum size, and `-KadrRTL` on Settings, All-in-One, editor, and studio.

## Runtime validation (docs/14 §6)

Mixed-DPI placement, window restoration, notch hit testing, and VoiceOver order
need a real GUI/TCC session. Document what could not be verified in-sandbox in
the PR.

## D5 protocol (cannot run in-sandbox)

Moderated sessions with at least: a first-time macOS user; a keyboard-heavy
power user; a VoiceOver or Full Keyboard Access user; a creator editing a
10-minute recording; a multi-display user with a notched laptop. Measure
completion, time, errors, backtracking, and whether help text was needed.
