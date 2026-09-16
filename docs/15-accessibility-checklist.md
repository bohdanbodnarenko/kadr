# Accessibility audit checklist

Companion to `docs/14-ux-ui-excellence-plan.md` D0 / UX-02. Run in a release-like
install with Screen Recording granted. Record the Accessibility Inspector hierarchy
and a keyboard-only pass for each flow.

## Surfaces

| Surface | Keyboard-only | VoiceOver | Inspector audit | Notes |
|---|---|---|---|---|
| Onboarding | code | code | GUI | Escape is not Back; Skip explains capture will not work; RTL via `-KadrRTL` |
| Settings | code | code | GUI | View ▸ Show/Hide Sidebar (⌃⌘S); Learn More popovers; value rows adjustable |
| Quick Access | code | code | GUI | Actions without hover; Share labelled; 20 pt hits |
| History | code | code | GUI | Search in toolbar; Finder-style selection; Trash |
| Pins | code | code | GUI | Click-through announced |
| Area selection | code | code | GUI | Semantic sibling tree; confirm mode optional; snap haptic |
| Window selection | code | code | GUI | ⌘ child windows |
| Countdown | code | code | GUI | Escape cancels; ticks announced |
| Recording setup / pre-roll / notch | code | code | GUI | More menu; Allow / Open Settings / Use Without; Reduce Motion |
| Annotation editor | code | code | GUI | Menus, inspector, export progress, local Help |
| Studio | code | code | GUI | Copy/Share is the edit; transcript words; timeline snap |

`code` means labels, hits, and keyboard actions are covered by package/app tests.
`GUI` means Accessibility Inspector recordings still belong with release evidence.

## Keyboard flows that must complete

1. Capture setup (All-in-One or hotkey) → commit or cancel
2. Card Copy / Save / Annotate / Hide / Delete
3. History select, range, Select All, Reveal, Delete (Undo via Trash)
4. Annotation: tool, draw, inspector, crop, export, close
5. Studio: play, trim, zoom cue, transcript cut, export, close

## Automated

Package and app tests cover accessibility labels, hit-target sizes, layout
minimums, capture-access prompts, and 1.4× / 2× string expansion. End-to-end
VoiceOver and TCC-gated GUI checks cannot run in the sandbox; attach recordings
to the release evidence.

Launch the agent with:

- `-KadrPseudolocalize` — expand strings ~1.4× at declared minimum window sizes
- `-KadrPseudolocalize2x` — 2× stress case (docs/14 §6 item 13)
- `-KadrRTL` — force right-to-left layout in English

## Verified in-sandbox

- `make lint`, `make check`, `make build`, `make build-editor`
- `KadrTests`: 319 tests including UX layout, access-gate, All-in-One titles, and
  1.4× / 2× expansion
- `SelectionUI`: 92 tests including snap alignment (`isAlignedToEdge`)
- `EditorUI`: `TimelineSnapTests` pass; `StudioPlaybackTests` remain a pre-existing
  flake under load (playhead clock vs suite contention) and were not changed for
  this plan

## Could not verify in-sandbox (GUI / TCC)

These remain for a release-like install with Screen Recording granted:

- Mixed-DPI HUD, card, pin, and alert placement (docs/14 §6 items 1–2)
- Selection badge / loupe / hint collisions at screen edges
- Quick Access vs Dock, Stage Manager, and full-screen Spaces
- Notch hit-testing around the camera housing
- VoiceOver reading order across inspector disclosure and banners
- Light/Dark, Graphite, Increase Contrast, Reduce Transparency, Reduce Motion
  together on recording chrome and custom materials
- Moderated D5 tasks (first-time, keyboard, VoiceOver, 10-minute studio, notch)
- Screenshot fixture capture listed in `docs/ux-fixtures/README.md`

An XCUITest target is not in CI: the agent is `LSUIElement` and capture is
TCC-gated, so Accessibility Inspector recordings belong with the release
evidence rather than the package matrix.
