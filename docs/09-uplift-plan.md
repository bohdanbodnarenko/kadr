# Uplift Plan — Better, Faster, Easier, Best-in-Class Editing

> The post-M18 roadmap, superseding the ordering of docs/06 for what remains. Inputs: the code review (`07-code-review-2026-08.md`) and the Screendrop analysis (`08-screendrop-analysis.md`). Structure: four sprints of "U" milestones. Work them like docs/06 milestones — one per branch, read the referenced doc sections first, verify the Done-when list. M19 (automation) stays in flight and merges independently; M20–M25 slot in after U1 unless noted.
>
> Non-negotiables carried forward: every U-milestone keeps the agent idle budget untouched (CI `phys_footprint` delta = 0), touches nothing in `Engine/`-tainted Screendrop code (reimplement, don't copy — see 08 §1), and adds tests for everything ported (Screendrop has none; that's our edge).

---

## Sprint U0 — Fix what the review found (1–2 weeks, blocks everything)

The signature interaction is broken under default settings (C1); recording can brick (C3); the editor fights the user (C2). Nothing new ships before these.

**U0.1 — File-promise drags everywhere** *(fixes C1 + H1)*
`NSViewRepresentable` drag source wrapping `NSFilePromiseProvider` for Quick Access cards, history grid, pins, and the editor proxy icon; staged files finalize inside the promise callback (never before); `overlayDismissOnDrag` acts on drop completion, not drag start. Done when: drag from a staged card into Slack/Mail/Finder/Chrome delivers the correctly named file; a cancelled drag leaves the card and staging intact; UI test covers staged + finalized paths.

**U0.2 — Editor drag & undo correctness** *(fixes C2)*
Select-mode moves preview from `dragStartRects` + absolute delta; exactly one history entry per completed gesture (same rule for resize/rotate once they exist); delete the dead compounding path. Done when: a 100 px drag moves 100 px; one drag = one undo step; new table-driven drag tests in EditorUI pass; undo depth after 50 drags ≥ 50.

**U0.3 — Recording lifecycle hardening** *(fixes C3, H2, H6, M2, M5, M6)*
`defer`-based cleanup in `stop()` so a failed stitch returns to `.idle` and surfaces the segment directory; mic capture implemented (SCK `captureMicrophone` on 15+, AVCaptureSession fallback on 14, separate track) or the toggle removed; `.bufferingNewest(3)` on the sample stream; one recording clock driving overlay effect timestamps (pause-aware); stitch cancellation guarded by state; collision-countered recording filenames with `.withoutOverwriting`. Done when: RecordingEngine state machine has unit tests covering stop-failure, cancel-during-stitch, and pause/resume timestamp math; kill-disk-space test recovers footage.

**U0.4 — Output policy correctness** *(fixes H3, H4, H5, M1, M4)*
Hygiene (`beginCapture` + settle) runs *before* any SCK call on every path; export moved off the main actor (async exporter, pasteboard write returns to main); card Delete removes the history record by content hash; pasteboard types derived from UTType (URL objects for video); multi-display capture routed through the batch `deliver(_ captures:)`. Done when: hidden-icons capture shows no icons; selection→clipboard signpost < 150 ms for 5K on M1; delete leaves nothing in App Support; existing perf harness green.

**U0.5 — Editor & polish debt** *(fixes M3, M7, M8, M9, M10, M11 + LOWs)*
Per-cell pixelate jitter (custom CIKernel or CPU pass) making the docs/03 security claim true; unsaved-changes prompt + `.kadr` autosave sidecar in the editor (activates the dead write path early — pulls a slice of M24 forward); OCR wired on cards and pins, Trim on recording cards; pin resize decode debounced to `viewDidEndLiveResize`; GIF encode chunked or duration-capped with the honest estimate; automation `pinFile` finalizes staged paths; own-window exclusion in region/scroll captures; temp poster cleanup. Done when: each corresponding review item's failure scenario has a regression test or is demonstrably impossible.

---

## Sprint U1 — Editor uplift: "even better editing, keeping everything" (3–5 weeks)

Ports from Screendrop's CC0 (non-Engine) code into our layered packages, with tests. All rendering lands in `AnnotationRender`, models in `AnnotationModel`, Vision in `VisionServices`; the editor app only grows UI.

**U1.1 — Beautify 2.0: the background subsystem** *(from 08 §2.1)*
Port the settings model (normalized-to-shortest-edge metrics), pure layout function, and renderer: 16+16 curated solids/gradients, custom wallpaper (bundled/user-imported only — no pack downloads), 9-way alignment with **stuck-edge zero-padding + per-corner radius**, even-odd shadow knockout, bucketed wallpaper decode cache. Replaces our simpler M17 beautify internals; UI keeps our panel, gains alignment + curated palettes. Done when: layout function is golden-tested against Screendrop-parity fixtures; a transparent-window capture over a gradient shows no black shadow backing; alignment-stuck exports match the reference look.

**U1.2 — Perspective camera** *(from 08 §2.2)*
Port `AnnotationCameraGeometry` math (pinhole → quad → invertible homography) as a pure `AnnotationModel` type with table-driven tests; render via `CIFilter.perspectiveTransform` drawn through `CIContext(cgContext:)`; hit-testing through the inverse homography so editing stays live while tilted; inspector with tilt/orbit/roll/FOV/zoom/pan.

**U1.3 — Progressive blur + the settle-preview pattern**
Radial and directional variable blur with clipped/scene edge modes (`maskedVariableBlur` + gradient masks); adopt the **cheap-live-preview-then-real-render-on-settle** pattern as a shared editor facility and retrofit it to any effect over 16 ms (perspective included).

**U1.4 — Borders & watermarks**
Screenshot border ring (thickness as fraction of shortest edge) unified with the shadow/card geometry; tiled rotated text watermark (density/size/rotation/opacity/color). Both as ordinary undoable commands.

**U1.5 — Inspector 2.0 + presets**
Port the scrub-track slider with typed suffix entry ("45%", "12px", "30deg", "1.5×") as the standard editor control; add the **style-preset system**: named presets over the full background/camera/blur/border/watermark state, active-preset tracking with "edited" detection, recovery copy, schema-versioned Codable (adopt their `decodeIfPresent`-defaults discipline everywhere we persist).

**U1.6 — Smart redaction 2.0** *(upgrades M18)*
Port the recognizer ruleset into `VisionServices` behind our existing XPC: Luhn-checked cards, JWT/API-key prefixes, value-only redaction after `password:`/`token=` separators via sub-range `boundingBox(for:)`, overlap merge/dedupe. Combined with U0.5's real pixelate jitter we end up strictly stronger than both our M18 and Screendrop. Done when: the seeded 10-secret fixture from M18 plus 10 new cases (JWTs, `token=` values, cards failing Luhn as negatives) all pass.

**U1.7 — Arrow bindings (clean-room)**
Reimplement in our command model: arrows optionally bind endpoints to another command's geometry via normalized anchors; bound arrows follow moves/resizes and trim at the target's edge; unbind on target delete. No Engine/ code. Done when: binding survives undo/redo, `.kadr` round-trip, and target reordering; property-based tests on the trim math.

**U1.8 — Editor workflow glue**
Import-from-Finder (copy-then-edit into history, originals untouched; `CFBundleDocumentTypes`); crop upgraded with `CropRectEditor`-style math (8 handles, aspect presets, corner-anchored aspect lock) plus our expand-canvas — as commands, single undo system; text tool gains the live `NSTextView` overlay measured by the export layout (keeping our 5 style presets + pill).

*After U1, slot in M20 (searchable history), M21–M22 (ruler + color picker) from docs/06 — unchanged.*

---

## Sprint U2 — UX uplift: easier to use (2–3 weeks)

**U2.1 — Overlay mechanics 2.0** *(from 08 §2 UX)*
`interactiveRects` pass-through hit-testing for the card panel (clicks land on windows beneath everywhere except real controls); **peek-collapse** to an edge tab while an editor is open instead of hiding; engagement tracking cancels auto-close once a card is touched; unsaved-item awareness on quit; formalize the capture-exclusion registry for all our windows (also closes the review's own-window LOW).

**U2.2 — After-capture matrix**
Replace the single default-action setting with the per-type matrix (screenshot vs recording × overlay/copy/save/annotate/pin/open-editor), migrating existing prefs to equivalent matrix rows. Recordings default to opening the (future) studio once U3 lands; until then, trim.

**U2.3 — Card layout editor**
Configurable card actions: corner slots + ordered center column, edited by drag-and-drop onto a live mock card in Settings. Ship with our current fixed layout as the default preset.

**U2.4 — Compress action**
One-click "copy compressed" (JPEG/HEIC target size) with a savings badge on the card; runs in HelperTools.

---

## Sprint U3 — Recording studio: the flagship (6–10 weeks, after U0–U2)

The Screen-Studio-class editor, built on Screendrop's proven designs but in our architecture: capture telemetry in the agent (tap is listen-only, active only while recording), everything else in the editor/helper processes. New package `StudioCore` (layer 2, depends on Shared + RecordingCore models).

**U3.1 — Session package + telemetry sidecar**
`.kadrrec` directory (screen.mov, camera.mov, input.json, capture.json, edit.json + edit.draft.json autosave split, render stamp, poster) in App Support with crash recovery; pointer capture with the triple-fallback design (listen-only CGEvent tap → AppKit monitors → sampler), **cursor artwork capture** (real cursor PNGs + hotspots), per-frame window geometry from SCK attachments, pause-aware timestamps, privacy-filtered keystrokes (chords/special keys only). Record with `showsCursor = false` once reconstruction exists (setting-gated until U3.2 proves out).

**U3.2 — Cursor & click reconstruction**
Sanitized event stream → edited-timeline re-integration with one shared damped spring; presses pixel-exact, motion smoothed; click ripple + keystroke captions rendered identically in preview and export (shared metrics). Replaces the M14 live-composited overlays for studio-edited exports (live overlays remain for instant MP4s).

**U3.3 — Virtual camera: zoom cues + smooth motion**
Cue model stored in *source* time (range, magnification, anchor mode) editable on a timeline; auto-generation from click clusters ("Add smart zooms"); smart anchors with immutable cluster centers; damped-spring integration along the edited timeline with follow-camera for 9:16/1:1/4:5; motion-blur supersampling at export. Preview and export share the precomputed timeline — determinism tested by frame-hash comparison.

**U3.4 — Clips, speed, camera bubble**
Non-destructive clip cuts + per-clip 1–8× speed via `AVMutableComposition.scaleTimeRange`; camera bubble from the separately-recorded camera.mov (position/size/roundness, layouts as presets).

**U3.5 — Social reframe + style presets**
Aspect presets (Original/16:9/9:16/1:1/4:5) with fill-mode camera re-planning; studio style presets sharing the U1.5 preset infrastructure.

**U3.6 — Transcript editing** *(stretch)*
Port the pure cut-planner (filler-word list, >1.1 s silence detection with 0.35 s padding, cuts bite into silence never words); transcription via `SFSpeechRecognizer` on macOS 14–15, SpeechAnalyzer on 26+ behind availability. Teleprompter stays in the backlog (macOS-26-only APIs, niche).

---

## Performance & quality gates (all sprints)

- Agent idle: `phys_footprint` delta = 0 for every U-milestone (all new capability lives in editor/helper/StudioCore).
- Editor: object-drag stays 60 fps on 5K after U1 (Instruments check in CI notes); settle-preview keeps slider interactions < 16 ms.
- Studio export: 1080p60 with camera motion ≤ 2× realtime on M1.
- Every port lands with tests Screendrop never had — pure math table-driven, renderers golden-imaged, state machines exhaustive. Zero-network CI check unchanged and still binding.
- License hygiene: PR template gains a checkbox — "contains no code derived from Screendrop's `Engine/` or other non-permissive sources."

## Sequence summary

**U0 (fix) → U1 (editor) → U2 (UX) → U3 (studio)**, with M19 merging when ready and M20–M22 interleaving after U1. This ordering front-loads user-visible trust (the broken drag is today's worst bug), then compounds our biggest differentiator (editing), then widens ease-of-use, then lands the flagship that no free tool ships polished.
