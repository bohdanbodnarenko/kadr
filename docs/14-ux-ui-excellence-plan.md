# UX/UI Excellence Plan

> App-wide static audit and implementation guide, 2026-09-14.
>
> This plan complements `10-road-to-v1.md`; it does not replace the functional or
> architectural roadmap. Product behavior remains governed by `03-features.md`, and
> implementation boundaries remain governed by `04-swift-architecture.md` and `CLAUDE.md`.

## 1. Goal

Make Kadr feel like a first-party macOS utility: immediate during capture, calm after
capture, precise in the editor, and predictable in the studio. The result should keep
Kadr's existing functional depth while removing clipping, layout shifts, hidden
interactions, nonstandard controls, ambiguous actions, accessibility gaps, and prose-heavy
settings.

The desired emotional result is **calm confidence**:

- The common action is obvious without reading instructions.
- Every action responds immediately and reports success or failure in place.
- Window resizing, long filenames, long recordings, and longer translated strings never
  break the layout.
- Pointer, keyboard, VoiceOver, Full Keyboard Access, and reduced-motion users can complete
  the same workflows.
- Destructive actions are reversible where possible and confirmed only when necessary.
- Custom surfaces still look native in Light, Dark, increased-contrast,
  reduced-transparency, and reduced-motion modes.

## 2. Audit basis and limits

### Sources

- Apple Human Interface Guidelines:
  [Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
  [Windows](https://developer.apple.com/design/human-interface-guidelines/windows),
  [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
  [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views),
  [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons),
  [Menus](https://developer.apple.com/design/human-interface-guidelines/menus),
  [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback),
  [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts),
  [Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
  [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
  and [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection).
- The Apple fluid-interface principles in the repository's `apple-design` skill:
  immediate response, direct manipulation, interruptibility, velocity continuity,
  spatially symmetric transitions, restrained spring motion, and accessibility variants.
- Kadr's authoritative behavior in `03-features.md`, architecture in
  `04-swift-architecture.md`, competitive reference in `08-screendrop-analysis.md`, and
  current v1 work in `10-road-to-v1.md`.

### Evidence levels

- **Confirmed:** directly evidenced by current source structure, sizing, interaction, or
  API choice.
- **Runtime validation:** plausible from source but must be reproduced in the installed
  app before changing behavior.
- **Visual refinement:** intentionally deferred until representative screenshots and
  recordings exist; do not tune colors and spacing by taste alone.

This is primarily a source audit. Phase 0 below is mandatory because animation quality,
actual truncation, VoiceOver order, display placement, and transient panel behavior need a
real GUI/TCC session and cannot be proven by reading code.

## 3. What is already strong and must not regress

- AppKit owns windows and panels; selection remains CALayer-only on the pointer path.
- Settings use `NavigationSplitView`; editor and studio use the system inspector API.
- Screen-capture permissions are preflighted and optional grants are explained by feature.
- Quick Access uses file promises and distinguishes Hide from Delete.
- The editor keeps image content central and separates chrome from the 60 fps canvas.
- Inspector numeric controls already provide direct scrubbing plus typed values.
- Recording controls expose pause, restart, stop, discard, audio state, and pre-roll.
- Empty History and search-index states explain why content is unavailable.
- Reduced Motion is already honored in several important surfaces.
- System colors, SF Symbols, semantic button roles, and native pickers are widely used.

Treat these as regression requirements, not areas to redesign from scratch.

## 4. Priority model

- **P0:** data loss, privacy deception, or an unusable primary flow. None confirmed in this
  static UX audit; engineering defects in `10-road-to-v1.md` still retain their own priority.
- **P1:** primary flow breaks at supported sizes/input methods, action meaning is misleading,
  or failures are hidden.
- **P2:** recurring friction, nonstandard macOS behavior, weak hierarchy, or incomplete
  accessibility.
- **P3:** visual polish and delight after correctness and access are complete.

## 5. Confirmed findings and required changes

### 5.1 Cross-app foundations

#### UX-01 — No localization or pseudolocalization safety net (P1)

**Evidence:** user-facing strings are embedded throughout `Kadr/`, `KadrEditor/`, and
`Packages/EditorUI/`; there is no Kadr string catalog. Fixed-width and fixed-size surfaces
therefore have never been exercised with longer labels.

**Change:**

1. Add a String Catalog for the agent and editor, with translator comments for capture
   terms such as “pin”, “overlay”, “studio”, and “flatten”.
2. Use localized interpolation and pluralization for counts, durations, cards, captures,
   words, and files. Avoid manual `word\(count == 1 ? "" : "s")` constructions.
3. Add an internal pseudolocalization launch argument that expands text to roughly 1.4×,
   wraps every label that may wrap, and preserves single-line controls by adapting their
   surrounding layout.
4. Add right-to-left layout verification even if the first release ships only in English;
   use leading/trailing semantics and audit directional icons.

**Accept:** all primary windows and transient controls work under double-length
pseudolocalized text at their minimum supported size; no label overlaps, clips without a
tooltip, or pushes a primary action offscreen.

#### UX-02 — Accessibility behavior is not tested end to end (P1)

**Evidence:** labels exist on many icon buttons, but there are no Kadr UI accessibility
audits or keyboard/VoiceOver flow tests. Several custom gesture surfaces have no equivalent
accessibility action.

**Change:**

1. Add an Accessibility Inspector checklist and XCUITest accessibility audit for onboarding,
   settings, Quick Access, History, editor, and studio.
2. Require keyboard-only completion of capture setup, card actions, History selection,
   annotation, crop, timeline trim, zoom editing, transcript editing, export, and close.
3. Give every custom draggable value an adjustable action, explicit value, and alternate
   buttons/menu commands. A drag gesture must never be the only way to operate a feature.
4. Maintain stable focus when content changes. Return focus to the initiating control after
   dismissing popovers, alerts, crop mode, and temporary review strips.
5. Add “Differentiate without color” treatment: shape, label, or state glyph must accompany
   red/green/orange status.

**Accept:** VoiceOver reaches every action promised by `03-features.md`; Full Keyboard
Access exposes visible focus in a logical order; automated audits have no unlabeled,
unsupported, or clipped elements.

#### UX-03 — Custom material, contrast, and motion behavior is inconsistent (P2)

**Evidence:** Quick Access, recording chrome, teleprompter, studio timeline, and editor
floating controls use custom opacities and materials. Reduced Motion is handled in
`OnboardingView`, `QuickAccessStackView`, `StudioRootView`, and inspector sections, but not
in `RecordingControlBarView`, `RecordingNotchIsland`, `RecordingPreRollBar`,
`StudioTranscriptPanel`, or every custom material surface.

**Change:**

- Introduce small, process-local environment policies for motion, transparency, and
  contrast. Do not put SwiftUI in `Shared`.
- Default to critically damped, interruptible motion with no decorative bounce. Preserve
  gesture velocity only for direct manipulation.
- Under Reduce Motion, replace spatial slide/scale with a short opacity change or no
  transition. Stop auto-follow animation in the transcript.
- Under Reduce Transparency, use an opaque semantic background and defined border. Under
  Increase Contrast, strengthen boundaries and selected states.
- Test custom forced-dark card chrome against white, black, high-saturation, and detailed
  captures.

**Accept:** every animation and custom material has explicit behavior for all three
accessibility settings; no status is communicated by color or opacity alone.

#### UX-04 — Typography has hard-coded subminimum text (P2)

**Evidence:** the studio ruler uses 9 pt text in
`Packages/EditorUI/Sources/EditorUI/StudioTimelineView.swift:290`; several dense surfaces
use caption-2 text for essential values. Apple recommends 13 pt default and 10 pt minimum
on macOS.

**Change:** use semantic macOS text styles and monospaced digits only where alignment needs
them. Keep essential values at 11–13 pt; use 10 pt only for genuinely secondary ruler
labels. Never put actionable or state-critical text in caption-2.

**Accept:** no user-facing text is below 10 pt; recording state, dimensions, time, export
progress, and warnings remain readable at normal viewing distance.

#### UX-05 — The app lacks a reusable responsive-layout contract (P1)

**Evidence:** independent views choose fixed widths, fixed one-row layouts, and separate
minimum-window sizes. Several combinations are mathematically impossible at their declared
minimum widths.

**Change:**

- Define compact, regular, and expanded presentation rules per surface using
  `ViewThatFits`, `Layout`, toolbar overflow, and priority-based omission of secondary
  metadata.
- Establish rules: primary action never disappears; secondary actions move into an overflow
  menu; labels wrap only in content areas, not toolbars; one-line values truncate in the
  middle and expose the full value through Help/VoiceOver.
- Add layout tests at 1× and 2× for 1024×768 through large displays, including notched safe
  areas and 1.4× pseudolocalized strings.

### 5.2 Menu bar, onboarding, and permissions

#### UX-06 — Permission rows can become cramped and text-heavy (P2)

**Evidence:** `Kadr/Onboarding/AppPermission.swift:167-187` combines icon, title,
Required/Optional badge, multiline explanation, and a minimum-88-point action in one
horizontal row. Recovery instructions add more text below.

**Change:** use `ViewThatFits` to switch to a stacked action below the copy when horizontal
space is insufficient. Replace the plain “Required/Optional” text with a concise semantic
badge, but keep the same information in VoiceOver. Show one recovery instruction tied to
the current state; avoid repeating relaunch guidance on every row.

**Accept:** rows remain aligned without compressing titles at 520 pt and under expanded
text; the current status and next action are understandable without reading all supporting
copy.

#### UX-07 — Onboarding does not visibly distinguish skip-for-now from cancel (P2)

**Evidence:** `Kadr/Onboarding/OnboardingView.swift:269-289` binds “Skip Setup” to the
cancel-action shortcut on every step while Back may also be present.

**Change:** make Escape close the window only after a lightweight “You can finish setup
later from the menu bar” explanation when required screen access is absent. Keep “Skip for
Now” as a secondary text button and use a stable primary button location. On the permission
step, primary copy should reflect state: “Continue” when screen access is allowed,
“Continue Without Screen Access” otherwise.

**Accept:** nobody can mistake Escape for going back; skipping never implies that capture
will work normally; practice remains available.

#### UX-08 — Menu discoverability and command grouping need a native-macOS pass (P2)

**Evidence:** `Kadr/StatusItem/StatusItemController.swift:209-369` builds a long dynamic
menu with capture, utilities, picker, recording, history, overlays, setup, updates, and quit.
Most items are text-only, and unavailable reasons are not exposed.

**Change:** group commands by task with restrained separators; use familiar SF Symbols only
where they improve scanning; show current state with checkmarks; hide impossible contextual
items rather than leaving unexplained disabled commands. Keep shortcuts right-aligned via
`NSMenuItem`, not embedded text. Ensure recording commands occupy the first group only while
recording.

**Accept:** the common capture modes, current recording state, latest captures, History,
Settings, and Quit can each be found in one scan; keyboard traversal and VoiceOver announce
state and shortcuts.

#### UX-08A — The menu-bar item has no capture-armed state (P2)

**Evidence:** `StatusItemController` implements only idle and recording icons
(`Kadr/StatusItem/StatusItemController.swift:117-150`), while `03-features.md` §8.1
specifies idle, capture-armed, and recording states.

**Change:** add a restrained armed state for area/window/scroll selection and recording
setup, with recording always taking precedence. Restore idle on every cancellation and
failed-start path. Do not animate continuously or add an idle timer.

**Accept:** invoking any capture surface produces immediate menu-bar feedback, and every
exit path restores the correct icon state.

#### UX-08B — Opening the practice image prematurely completes onboarding (P2)

**Evidence:** `OnboardingModel.openPracticeImage()` calls `finish()` before opening the
sample (`Kadr/Onboarding/OnboardingModel.swift:202-210`).

**Change:** open the practice editor while preserving onboarding state, or require an
explicit “Finish Setup and Try the Editor” action. Returning from the editor must bring the
user back to their prior onboarding step and retain unsaved choices.

**Accept:** trying the sample does not silently skip defaults or mark onboarding complete.

### 5.3 Settings

#### UX-09 — Settings minimum sizes conflict, and the sidebar cannot collapse (P1)

**Evidence:** `SettingsView` requires at least 660×540 and fixes its sidebar to 200 pt
(`Kadr/Settings/SettingsView.swift:32-47`), while `SettingsWindowController` declares
620×460 (`Kadr/Settings/SettingsWindowController.swift:80-97`). The standard sidebar toggle
is explicitly removed.

**Change:**

1. Choose one tested minimum content size and use it in one source of truth.
2. Restore the system sidebar toggle and a View ▸ Show/Hide Sidebar command, or
   automatically collapse the sidebar below the regular breakpoint.
3. Persist sidebar visibility and width only through native split-view behavior.
4. Keep the selected pane and scroll position when resizing.

**Accept:** the window can reach its declared minimum without clipped controls; the detail
pane remains useful with the sidebar hidden; restored frames are clamped to the current
display.

#### UX-10 — Settings are prose-heavy and expose implementation details (P2)

**Evidence:** `RecordingPane.swift` and `CapturePane.swift` contain long paragraphs about
ten-bit codecs, camera strips, helper behavior, frame stitching, overlay composition, and
irreversible telemetry. These explanations compete with the controls.

**Change:** use one concise footer per decision. Move technical explanation to Help buttons
or a Learn More page. Lead with outcome:

- “Smaller files; required for HDR” instead of an encoding paragraph.
- “Separate tracks let you remove the microphone later” instead of pipeline details.
- “Editable recording data enables smooth cursor and zoom effects” with storage estimate
  and a clear dependency summary.

Use disclosure groups for advanced scrolling, overlay rendering, and studio capture
options. Keep common recording choices visible.

**Accept:** a first-time user can configure recording without reading more than one line
per group; advanced users can still find exact consequences before enabling privacy- or
storage-sensitive options.

#### UX-11 — Recording settings use unlabeled sliders without persistent values (P2)

**Evidence:** click size, keystroke size, webcam size, teleprompter pace, and text size use
plain `Slider` controls (`RecordingPane.swift:107-158`,
`TeleprompterSection.swift:28-51`). The editor already has the stronger labeled scrubber
plus typed field pattern.

**Change:** create an agent-local settings value row with label, system slider, and
persistent numeric value field. Do not import `EditorUI` into the agent. Use meaningful
units: percent, words/minute, and points. Arrow keys adjust by one displayed unit.

**Accept:** every numeric recording setting can be read and entered exactly; changing it
does not shift adjacent layout.

#### UX-12 — Card layout editing is drag-only and not keyboard accessible (P1)

**Evidence:** `Kadr/Settings/CardLayoutEditor.swift:81-180` uses draggable symbol-only chips,
drop destinations, Help, and a context-menu Remove action. There is no keyboard placement,
reordering, or explicit remove button.

**Change:** supplement the live preview with an accessible ordered list for each slot.
Provide Add, Remove, Move Earlier, Move Later, and Move to Slot commands. Preserve direct
dragging for pointer users and announce successful moves through accessibility notifications.

**Accept:** the entire layout can be configured with keyboard and VoiceOver; focus follows
the moved action; impossible drops explain why they failed.

#### UX-13 — Settings mutations can fail silently (P1)

**Evidence:** login-item changes only log errors in
`Kadr/Settings/GeneralPane.swift:87-97`; CLI results are shown as plain secondary copy and
can be pushed below the changed control.

**Change:** show inline status adjacent to the control with a recovery action. Revert a
toggle if registration fails. Announce status changes to VoiceOver. Keep success transient
but leave failures until dismissed or corrected.

**Accept:** every system-level setting either changes successfully or visibly returns to
its previous state with a useful next step.

### 5.4 Capture HUDs and recording chrome

#### UX-14 — All-in-One and recording setup are fixed single rows (P1)

**Evidence:** `AllInOneView` and `RecordSetupView` end in `.fixedSize()` and place every mode
or option in one `HStack` (`Kadr/Capture/AllInOneHUD.swift:192-228`,
`Kadr/Recording/RecordSetupHUD.swift:157-176`). Eight capture modes plus options, or three
sources plus five inputs and timer, cannot adapt to small displays or longer labels.

**Change:**

- Use a compact layout that keeps Area, Window, Screen, and Record visible and moves less
  frequent modes/options into a labeled More menu when width is constrained.
- Use `ViewThatFits` to choose a full strip, two-row palette, or compact overflow form.
- Preserve stable button positions while device discovery completes; show unavailable
  camera/microphone states in menus instead of adding/removing controls.
- Keep Escape, Return, single-letter shortcuts, and VoiceOver actions equivalent.

**Accept:** the HUD stays within `visibleFrame` and safe areas on every supported display;
device refresh does not resize or recenter the panel after presentation.

#### UX-15 — Recording motion ignores Reduce Motion in key surfaces (P1)

**Evidence:** unconditional `.snappy` and spring animations appear in
`RecordingControlBar.swift:350-437`, `RecordingNotchIsland.swift:30-37`, and
`RecordingPreRollBar.swift`.

**Change:** route all recording transitions through one motion policy. Under Reduce Motion,
cross-fade state changes and disable notch expansion movement. All animation must begin from
the presentation value and remain interruptible if the pointer re-enters.

**Accept:** toggling pause, silent-mic state, pre-roll, and notch expansion creates no
spatial motion under Reduce Motion; rapid reversals do not jump.

#### UX-16 — Hover-only notch expansion hides important actions (P1)

**Evidence:** restart and discard exist only when `layout.isExpanded`, and expansion is
driven by `.onHover` in `RecordingNotchIsland.swift:38-49`. Keyboard and assistive users
cannot intentionally reveal the expanded controls.

**Change:** keep Stop and Pause permanently visible, and add an explicit More button that
opens Restart and Discard. Hover may preview expansion but cannot be the only trigger.
Provide the same menu through keyboard and VoiceOver.

**Accept:** every recording command is reachable without a pointer and remains reachable
when hover tracking is unavailable.

#### UX-17 — Recording and capture setup need live permission/device states (P2)

**Evidence:** camera and microphone controls disable or disappear when unavailable, but
compact chrome mostly explains state through Help text. Permissions are often requested
only after a recording decision.

**Change:** when a chosen option needs access, show a compact anchored popover before target
selection with “Allow”, “Open Settings”, or “Use Without”. Preserve the user's setup and
resume after access changes. Never reopen screen-recording permission when preflight says it
is granted.

**Accept:** starting a recording never fails into an unexplained disabled control; denying
camera/microphone still starts a screen-only recording after one clear choice.

#### UX-17A — Still-capture countdown cannot satisfy Escape-to-cancel and uses the wrong screen (P1)

**Evidence:** `CaptureCountdown.run` always chooses `NSScreen.main` and only exposes
programmatic cancellation (`Kadr/Capture/CaptureCountdown.swift:32-80`). Its own comment
states that Escape is not handled, although `03-features.md` §1.5 requires it.

**Change:**

1. Pass the target display or `CGDirectDisplayID` into the countdown; never infer it from
   `NSScreen.main`.
2. Implement Escape cancellation without adding an Accessibility requirement. Prefer a
   temporary cancellable responder owned by the active capture session; if macOS cannot
   deliver Escape without activation, visibly document and support the same capture
   shortcut as the fallback, but resolve the spec deliberately rather than only in a code
   comment.
3. Keep the panel click-through and excluded from capture.

**Accept:** the badge appears on the display being captured; Escape cancels before pixels
are delivered; no panel, task, or armed icon survives cancellation.

#### UX-17B — Countdown and selection surfaces are absent from the accessibility tree (P1)

**Evidence:** `CountdownPanel` and `SelectionOverlayView` are CALayer-based and publish no
`NSAccessibilityElement`, label, value, custom action, or announcement. Keyboard selection
exists, but VoiceOver cannot discover the mode, selection dimensions, window title, or
commit/cancel actions.

**Change:** keep the visual mouse path CALayer-only, but add a lightweight semantic sibling
tree owned by the AppKit panel. Expose mode, current rectangle in points and pixels,
window/app name, loupe color/coordinates when requested, and Commit, Cancel, Switch Mode,
and Capture Display actions. Announce countdown ticks and meaningful phase changes without
announcing every pointer move.

**Accept:** VoiceOver can complete area and window capture; Accessibility Inspector shows a
stable, bounded element tree; pointer-path performance is unchanged.

#### UX-17C — Several documented capture affordances are missing (P2)

**Evidence:**

- area selection commits immediately on mouse-up
  (`Packages/SelectionUI/Sources/SelectionUI/SelectionOverlayView.swift:277-291`); the
  optional confirm mode and resize handles in `03-features.md` §1.1 are absent;
- window selection implements same-app Tab cycling and Option shadow inversion, but not
  Command-held child-window/panel selection from §1.2;
- All-in-One exposes timer and aspect only, not the save-target and recording-audio options
  specified in §1.4; its timer menu omits the configured custom duration.

**Change:** add the off-by-default confirm-selection preference and CALayer handles; add
child/panel filtering while Command is held; complete the All-in-One options model or
explicitly revise the product spec if recording options intentionally belong only to the
next strip. Show the active custom timer value.

**Accept:** each behavior has an interaction test and a visible teaching hint; confirm mode
adds no latency when disabled.

#### UX-17D — Recording pre-roll does not have consistent Escape or VoiceOver behavior (P2)

**Evidence:** setup HUDs use `.onExitCommand`, but `RecordingPreRollBar` does not; notch
pre-roll cancellation is button-only. Notch microphone, audio, and camera toggles have Help
text but no explicit accessibility label/value.

**Change:** make Escape cancel pre-roll in both floating and notch variants, and give every
toggle the same label/value semantics as `RecordSetupView`. Preserve the recording shortcut
as a second cancellation path.

**Accept:** pre-roll can be cancelled from keyboard and VoiceOver in every chrome style;
the spoken state matches the actual inputs.

### 5.5 Quick Access, History, pins, and OCR

#### UX-18 — Quick Access actions are pointer-hover dependent (P1)

**Evidence:** `QuickAccessCardView` creates `hoverChrome` only when `isHovering` or the
always-show preference is true (`Kadr/QuickAccess/QuickAccessCardView.swift:133-152,
202-207`). The card's accessibility label says “Hover for the actions”.

**Change:** implement the specified sticky single-click expansion; `onTap` is currently
empty (`QuickAccessCardView.swift:240-259`). Render actions for accessibility even when
visually hidden, or provide an explicit focus/menu mode that reveals them. Keyboard focus
entering a card must reveal chrome. VoiceOver must expose Copy, Save, Save As,
Annotate/Studio, Pin, OCR, Share, Hide, and Delete as named actions. Mirror configured
actions in the context menu and add an explicit accessibility label to `ShareLink`. Do not
require users to enable “Always show actions” for access.

**Accept:** every visible card action passes the `03-features.md` VoiceOver criterion and
can be triggered with no pointer.

#### UX-19 — Quick Access controls and metadata do not adapt at small card sizes (P2)

**Evidence:** card width is configurable down to 140 pt while details combine filename,
dimensions, size, compression state, and staging icon in one line
(`QuickAccessCardView.swift:306-329`). Close controls use 18 pt frames
(`:372-393`), below Apple's 20 pt minimum target.

**Change:** at compact sizes show filename plus one priority status and move dimensions,
size, and storage state into Help/VoiceOver/context menu. Increase every action target to at
least 20×20 pt, preferably 28×28 pt, without visually enlarging every glyph.

**Accept:** metadata never overlaps actions at 140 pt; all pointer targets meet minimum size;
the full filename and dimensions remain discoverable.

#### UX-20 — History's header cannot fit its minimum window (P1)

**Evidence:** History declares a 560 pt minimum, but its one-row header contains a segmented
type picker (up to 360), date picker (up to 160), 200 pt search field, two text buttons,
spacing, and 32 pt padding (`Kadr/History/HistoryView.swift:149-179`).

**Change:** move search into the native toolbar with `.searchable`; put Type and Date in
compact pull-down controls or a filter popover; move Reveal and Delete to the toolbar or
selection context. Use toolbar item priority/overflow. Keep selection count and storage in
the footer.

**Accept:** at 560 pt, all primary functions remain available with no compression-induced
truncation or horizontal overflow; at larger widths the controls may expand without moving
the grid.

#### UX-21 — History reimplements collection selection incompletely (P1)

**Evidence:** selection is manually inferred from global modifier flags
(`HistoryView.swift:335-358`), and cells are custom drag overlays rather than a native
selection container. There is no arrow-key navigation, focus model, Select All, or stable
range anchor.

**Change:** use a native selectable collection/table where practical, or implement an
explicit selection model with anchor, focused item, arrows, Space, Return, Command-A,
Command-click, Shift-click, and keyboard context actions. Keep file-promise drag behavior.

**Accept:** Finder-style selection works consistently by pointer and keyboard; selection
survives thumbnail loads and pagination; focus and selection are visually distinct.

#### UX-22 — History deletion is immediate and irreversible in the UI (P1)

**Evidence:** toolbar, Delete key, and context-menu Delete call deletion directly
(`HistoryView.swift:173-176, 269-275, 369-375`). The stored file is removed as part of the
privacy-correct behavior.

**Change:** prefer reversible deletion: move to Trash or maintain a short-lived Recently
Deleted queue with Undo. If a batch cannot be recovered, use a sheet that states the item
count and consequence. Do not show a confirmation for a single reversible delete.

**Accept:** an accidental Delete keypress is recoverable; batch permanent deletion names
the number of files; focus moves predictably after removal.

#### UX-23 — History loading has no visible state when records exist or first load is slow (P2)

**Evidence:** the empty state is suppressed while `isLoading`, but no first-load progress
view is shown; pagination starts when the last cell appears.

**Change:** show a centered initial progress state, preserve existing cells during
pagination, and add a small nonblocking footer indicator for load-more. On failure, retain
loaded results and offer Retry inline.

**Accept:** no blank window appears during load; adding pages does not shift the current
scroll position.

#### UX-24 — OCR, pin, and card feedback needs one coherent model (P2)

**Change:** standardize status feedback as:

- completion: transient in-place confirmation only when the result is not otherwise visible;
- warning: persistent inline banner with action;
- error: anchored alert/sheet only when user choice is required;
- progress: determinate when measurable, cancellable for work over roughly one second.

Apply this to copy, compressed copy, OCR, save, drag finalization, pin, GIF export, and
stitching. Keep card geometry stable while status changes; reserve a status overlay instead
of inserting labels that resize the card.

#### UX-24A — Pinned screenshots have no semantic accessibility model (P1)

**Evidence:** `PinPanel` and its image content expose no accessibility role, label, value,
or actions. Click-through state changes `ignoresMouseEvents` and displays a 10 pt badge
(`Kadr/Pins/PinPanel.swift:250-288`) but does not announce the new state.

**Change:** expose each pin as an image/reference element with filename, dimensions, zoom,
opacity, and click-through state. Add Copy, Save, Annotate, OCR, Toggle Click-Through, and
Close custom actions. Post a focused announcement when click-through changes and include
the shortcut in accessibility help.

**Accept:** VoiceOver can identify, operate, and exit click-through mode for every pin.

#### UX-24B — Several user-initiated failures are logger-only (P1)

**Evidence:** missing editor, OCR, GIF, compression, and some History failures log errors
without visible recovery. Disabled card actions can say “coming soon” when the real cause is
that the embedded editor is unavailable.

**Change:** route every user-initiated action through the feedback model in UX-24. Store a
typed unavailable reason separately from feature availability; say “Editor is not
installed” or “Could not read text” rather than “coming soon”. Offer Retry, Open Settings,
Choose Location, or Reinstall as appropriate.

**Accept:** clicking an unavailable or failed action produces a specific visible result
within one second; no actionable failure exists only in logs.

#### UX-24C — OCR and recent-capture feedback is only partially accessible (P2)

**Evidence:** the OCR toast labels only its dismiss control; the review window has limited
grouping; recent-capture strip buttons use tooltips but no record-specific accessibility
labels.

**Change:** announce “Text copied” with character count, expose preview and link/table
actions, and label each recent thumbnail with kind, filename, dimensions, and timestamp.

**Accept:** VoiceOver can distinguish every recent item and complete OCR review without
guessing what was copied.

### 5.6 Annotation editor

#### UX-25 — The editor toolbar cannot fit its own minimum window (P1)

**Evidence:** `EditorToolbar` places roughly thirteen drawing tools, six history/orientation
commands, Auto-redact, Remove Background, Copy, More, Save, and Inspector in one `HStack`
(`Packages/EditorUI/Sources/EditorUI/EditorToolbar.swift:12-45, 104-242`). The editor allows
a 760 pt minimum and `EditorRootView` still declares 720 pt.

**Change:**

1. Move primary document actions into the real macOS window toolbar using `NSToolbar` or
   SwiftUI toolbar items hosted by the window controller.
2. Keep Select plus the most-used drawing tools visible; group shape variants and
   redaction variants in menus. Move rotate/flip and less frequent ML actions into
   overflow when constrained.
3. Use toolbar placement priority and the system overflow menu rather than clipping.
4. Keep tool choice stable while the toolbar changes width; do not reorder controls during
   a gesture.
5. Unify the root and window-controller minimum size in `EditorWindowGeometry`.

**Accept:** every command remains available at minimum width; no toolbar item overlaps,
shrinks below its hit target, or moves unexpectedly when selection changes.

#### UX-26 — Editor export failures can be silent (P1)

**Evidence:** `EditorWindowController.exportRendered` catches render errors and only logs
them (`KadrEditor/EditorWindowController.swift:256-281`). A failed Save/Copy/Share can appear
to succeed.

**Change:** perform expensive rendering asynchronously with visible progress and
cancellation. Report failure in a window-attached banner or sheet with Retry and, for save
failure, Choose Another Location. Only show the copied toast after pasteboard success.

**Accept:** every export action has observable start/completion/failure; a 5K render does not
block window input; failed save never clears dirty state.

#### UX-27 — Editor command infrastructure bypasses the responder chain (P1)

**Evidence:** `EditorRootView.swift:139-176` creates invisible 0×0 buttons to register
keyboard shortcuts. The app Edit menu sends generic Undo/Redo/Copy/Paste/Select All
selectors, but `EditorWindowController` is not inserted into the responder chain and does
not implement the annotation commands. `StudioWindowController` already contains the
correct responder-chain pattern.

**Change:** mirror the studio implementation: make `EditorWindowController` an
`NSResponder`, insert it after the window, implement and validate Undo, Redo, Cut, Copy,
Paste, Select All, Duplicate, and layer-order commands against the key document. Focused
text editing must remain earlier in the chain. Remove invisible duplicate shortcut buttons
after menu parity is proven.

**Accept:** commands work for the key window only, appear in menus with shortcuts, validate
correctly, and do not depend on invisible controls in the view hierarchy.

#### UX-28 — The editor's app menu is incomplete for a regular document app (P2)

**Evidence:** `KadrEditor/EditorAppDelegate.swift:299-359` creates only minimal App, File,
and Edit menus. It omits standard About, Services, Hide Others, Show All, View, Window, and
Help commands.

**Change:** build the standard macOS menu structure. Add View ▸ Show/Hide Inspector, zoom,
and canvas commands; Window ▸ Minimize/Zoom/Bring All to Front; Help ▸ Kadr Help and
Keyboard Shortcuts. Keep custom object commands in Edit and validate every item.

**Accept:** system menu search finds editor commands; standard macOS shortcuts and Window
menu behavior work across multiple editor/studio windows.

#### UX-29 — Modal alerts block every editor window (P2)

**Evidence:** unsaved-work, autosave recovery, preset import, open failure, and quit paths
use synchronous `NSAlert.runModal()` in a multiwindow regular app.

**Change:** use window-attached sheets (`beginSheetModal`) for document-specific decisions.
Keep app-modal alerts only for application-wide termination decisions. Preserve focus and
support asynchronous save before completing close.

**Accept:** a decision in one document never blocks another document; the alert clearly
names the affected file and default/cancel buttons follow macOS conventions.

#### UX-30 — Inspector hierarchy is too long and not context-first enough (P2)

**Evidence:** `EditorInspector` appends selection actions, sticker/crop, looks, resize,
beautify, camera, blur, and watermark into one grouped Form. Important context controls can
sit far below global styling panels.

**Change:** order as Context → Selection → Canvas/Appearance → Export. Collapse advanced
global effects by default and remember disclosure state. When a tool is armed or an object
selected, place its controls first and scroll them into view without animation under Reduce
Motion. Put layer ordering in menu/shortcuts, not six permanent buttons.

**Accept:** selecting any object shows its relevant controls without scrolling; no global
panel jumps position as transient state appears.

#### UX-30A — Text inspector exposes ineffective controls and incomplete custom styling (P1)

**Evidence:** the generic tool section shows stroke-width presets and a Width slider for
Text, but applying stroke width is a no-op for text. The preset binding only changes style
memory and does not rewrite selected text. Custom font family, weight, size, and background
pill controls required by `03-features.md` §3 are incomplete.

**Change:** special-case Text before generic stroke controls. Show Preset, Font, Weight,
Size, Color, Alignment, and Background Pill. Implement `applyTextStyle` so a preset or
custom change updates both style memory and selected text as one undoable edit.

**Accept:** no visible text control is a no-op; selected text updates immediately and export
matches the live editor; table-driven tests cover all seven presets and custom properties.

#### UX-30B — Editor progress feedback is incomplete (P2)

**Evidence:** subject lifting only disables its toolbar button; trim export runs
asynchronously with no progress indicator. Smart-highlighter preparation can fall back
silently when OCR fails.

**Change:** show task-specific inline progress with cancellation where supported. If smart
highlighting degrades to freehand, state that briefly without blocking drawing. Trim export
must disable conflicting controls and expose progress/cancel.

**Accept:** work lasting over roughly one second is visibly active and cancellable where
safe; fallback behavior is explicit.

#### UX-30C — Editor-specific Reduce Motion coverage is incomplete (P2)

**Evidence:** copied-toast scale and crop transitions in `EditorRootView` animate
unconditionally even though studio chrome has a Reduce Motion policy.

**Change:** adopt the same policy in the annotation editor; use static appearance or opacity
only when Reduce Motion is enabled.

**Accept:** no scale, slide, or spring animation remains in editor chrome under Reduce
Motion.

### 5.7 Recording studio

#### UX-31 — “Copy” and “Share” act on the original, not the visible edit (P1)

**Evidence:** `StudioRootView.swift:226-238` labels controls “Copy” and “Share” while Help
reveals that they send the original recording.

**Change:** the default action must match the preview. Make Copy/Share export the current
edit, reusing an up-to-date render when available. Put “Copy Original” and “Share Original”
in an overflow menu. If rendering is required, show progress and continue the requested
action automatically after export.

**Accept:** clicking Copy or Share always produces what the preview shows; original-media
actions are explicit and never rely on tooltip clarification.

#### UX-32 — Studio timeline is pointer-first and below minimum hit sizes (P1)

**Evidence:** clip trim targets are 8 pt wide (`StudioTimelineView.swift:358-384`), zoom
resize targets are 10 pt (`StudioZoomLane.swift:121-151`), and creation/scrubbing relies on
drag gestures. Most custom timeline objects have no accessibility representation.

**Change:**

- Expand invisible hit regions to at least 20 pt without changing visual handles.
- Add keyboard selection and trimming: arrows nudge playhead, Shift-arrows extend trim,
  Option-arrows use larger steps, Return opens the selected cue/clip, Delete removes with
  Undo.
- Represent clips, zooms, playhead, and crop handles as accessible adjustable elements
  with time/value announcements.
- Add snapping feedback and optional alignment haptic at meaningful boundaries.

**Accept:** a precise cut and zoom can be made without dragging; handles stay hittable at
every timeline zoom; VoiceOver reports source, edited time, range, speed, and enabled state.

#### UX-33 — Studio crop handles are decorative-size hit targets (P1)

**Evidence:** `StudioCropOverlay.swift:25-32` attaches gestures directly to 10×10 circles,
unlike the camera overlay, which wraps its 10 pt visual handle in a 22 pt frame.

**Change:** separate visual and interactive handle sizes, include edge handles as well as
corners where appropriate, set resize cursors, and add keyboard-adjustable crop edges.

**Accept:** every crop handle has at least a 20×20 hit target in view space and remains
reachable at preview edges.

#### UX-34 — Transcript words are gestures, not controls (P1)

**Evidence:** each transcript word is a `Text` with `.onTapGesture` and context menu
(`StudioTranscriptPanel.swift:171-185`). It has no button semantics, focus, selected state
announcement, keyboard range selection, or action hint. Auto-follow animation also ignores
Reduce Motion.

**Change:** expose words as accessible buttons or custom accessibility elements while
retaining the efficient flow layout. Add arrow navigation, Shift-range selection, Return to
seek, Delete to cut, and a named “Cut Sentence” action. Under Reduce Motion, scroll without
animation. Keep active-playback and selected states distinct beyond color.

**Accept:** VoiceOver can read continuously, seek, select a range, and cut; keyboard focus
is not stolen as playback advances.

#### UX-35 — Studio feedback is generic and sometimes unnecessarily modal (P2)

**Evidence:** every model failure is presented under “The studio could not do that” with one
OK button (`StudioRootView.swift:57-73`), regardless of whether the remedy is Settings,
retry, selecting audio, freeing storage, or choosing another destination.

**Change:** model failures as typed presentation states with severity, message, recovery
actions, and affected operation. Use inline banners for recoverable workflow errors and a
sheet only for decisions or destructive consequences. Keep successful notices anchored and
nonblocking, but pause auto-dismiss while pointer or VoiceOver focus is within the banner.

**Accept:** every known failure offers the next useful action; no generic alert interrupts
editing merely to report a noncritical condition.

#### UX-36 — Studio layout can shift when transcript, notice, export, or crop state changes (P2)

**Evidence:** the inspector changes from one pane to a `VSplitView` when a transcript
appears; the bottom control bar swaps its entire content in crop mode; export swaps a button
for progress controls.

**Change:** reserve stable regions for status and transport. Animate only the divider from
its current presentation position; remember transcript height. Keep Stop/Cancel export in
the same action cluster as Export. Crop may use a contextual toolbar but must not move the
preview or timeline.

**Accept:** playhead, timeline height, preview frame, and pointer target positions remain
stable across status, crop, transcript, and export changes.

#### UX-36A — Studio transport controls rely on tooltips for meaning (P1)

**Evidence:** playback, frame-step, jump, trim, speed, and timeline-zoom icon buttons use
`.help` but often omit explicit accessibility labels
(`Packages/EditorUI/Sources/EditorUI/StudioTransportBar.swift:85-174` and
`StudioTimelineView.swift:212-251`).

**Change:** label every icon control, provide current value/state, and group playback
controls semantically. Announce play/pause and selected clip/zoom without speaking every
frame.

**Accept:** VoiceOver identifies every transport command and its shortcut; automated
accessibility snapshots contain no icon-only unnamed controls.

## 6. Runtime-validation backlog

Validate these before assigning implementation work; promote reproducible items into the
confirmed list with screenshots, recordings, and exact steps.

1. Mixed-DPI and mixed-menu-bar display placement for all HUDs, cards, pins, and alerts.
2. Window restoration when a saved display is disconnected or changes scale.
3. Selection badge, loupe, and hint collisions at every screen edge and tiny selection.
4. Quick Access stack collision with Dock, Stage Manager, auto-hidden Dock, and full-screen
   Spaces.
5. Hover timeout continuity when moving through card gaps or between card and context menu.
6. Recording notch hit testing around the physical camera housing and menu extras.
7. Camera/device changes while the recording setup HUD is open.
8. Editor canvas centering, zoom, and handle reachability for portrait, panoramic,
   transparent, HDR, and very small captures.
9. Long annotation text editing near every canvas edge and under zoom/rotation/perspective.
10. Studio timeline responsiveness at 10 minutes and 60 minutes, with and without transcript.
11. VoiceOver reading order across inspector disclosure changes and transient banners.
12. Light/Dark, Graphite accent, multicolor accents, increased contrast, reduced
    transparency, color filters, and Reduce Motion.
13. Pseudolocalized 1.4× and 2× strings, long filenames, long device names, and long preset
    names.
14. All empty, loading, offline-model, permission-denied, disk-full, and cancelled states.

For each flow capture:

- a screen recording at normal speed;
- a 0.25× replay for motion discontinuities;
- Accessibility Inspector hierarchy;
- focus order from keyboard-only use;
- minimum-size and large-size screenshots;
- signpost timing for any path governed by PRD §8.

## 7. Implementation sequence

### D0 — Establish evidence and regression harness

1. Install a release-like agent and editor build.
2. Capture the runtime-validation matrix above.
3. Add screenshot fixtures for every major state at minimum/regular/large widths.
4. Add pseudolocalization and the accessibility audit target.
5. Record baseline task completion time and click/keystroke count for:
   first capture, first recording, copy/save from card, annotate and export, History
   recovery, trim/export, and studio zoom/cut/export.

**Done when:** every later visual PR has a reproducible before/after artifact and can fail a
test rather than relying on reviewer taste.

### D1 — Correct access, semantics, and misleading actions

Implement UX-02, UX-12, UX-17A, UX-17B, UX-18, UX-21, UX-22, UX-24A, UX-24B,
UX-26, UX-27, UX-30A, UX-31, UX-32, UX-33, UX-34, and UX-36A.

**Done when:** primary workflows are equivalent by pointer and keyboard; VoiceOver reaches
every promised action; Copy/Share/export actions always describe the actual result; no
failure is log-only.

### D2 — Make every surface responsive

Implement UX-01, UX-05, UX-06, UX-09, UX-14, UX-17C, UX-19, UX-20, UX-25, and UX-36.

**Done when:** the layout matrix passes across minimum sizes, supported displays, long
content, and pseudolocalized strings with zero overlap or inaccessible overflow.

### D3 — Restore native macOS structure

Implement UX-08, UX-08A, UX-08B, UX-10, UX-11, UX-13, UX-27, UX-28, UX-29,
UX-30, UX-30B, and UX-35.

**Done when:** toolbars, menus, inspectors, settings, sheets, focus, validation, and window
management behave like a regular macOS app while preserving the transient-process
architecture.

### D4 — Motion, materials, and craft

Implement UX-03, UX-04, UX-15, UX-16, UX-17, UX-17D, UX-23, UX-24, UX-24C,
and UX-30C, then perform the final visual refinement pass.

Polish in this order:

1. typography and hierarchy;
2. spacing and alignment on an 8/4 pt rhythm;
3. control/state contrast;
4. material and shadow depth;
5. enter/exit spatial consistency;
6. direct-manipulation springs and velocity handoff;
7. restrained haptic feedback for snapping/alignment only;
8. icon optical alignment and animation.

**Done when:** accessibility variants are complete first, motion remains interruptible, and
visual styling does not create new custom controls where a system component works.

### D5 — Usability validation and release gate

Run moderated tests with at least:

- a first-time macOS user;
- a keyboard-heavy power user;
- a VoiceOver or Full Keyboard Access user;
- a creator editing a 10-minute screen recording;
- a multi-display user with a notched laptop.

Measure successful completion, time, errors, backtracking, and whether help text was needed.
Fix blockers, repeat the same tasks, and attach results to the release checklist.

## 8. Review checklist for every UX PR

### Behavior

- Does the action do exactly what its label says?
- Is the common path visible and the advanced path one level deeper?
- Is destructive work undoable, or explicitly confirmed if truly irreversible?
- Are empty, loading, success, warning, error, cancellation, and recovery states covered?
- Does the flow resume after permission or file-panel detours?

### Layout and text

- Tested at minimum, regular, and large window sizes.
- Tested with long filenames, device names, durations, counts, and 1.4× strings.
- No fixed width without a documented content bound.
- Primary controls never wrap to two lines inside toolbars/HUDs.
- Multiline explanatory text uses semantic styles and is not truncated.
- Full values are available via Help and VoiceOver when visual truncation is intentional.

### Input and accessibility

- Pointer, keyboard, VoiceOver, and Full Keyboard Access reach equivalent actions.
- Visible focus, stable focus restoration, and logical reading order.
- Default control target 28×28 pt; absolute minimum 20×20 pt.
- Dragging is direct, respects grab offset, and has a non-drag alternative.
- Color is never the sole state indicator.
- Reduce Motion, Reduce Transparency, and Increase Contrast are explicitly verified.

### Motion

- Feedback begins on press and continues during direct manipulation.
- Gesture-driven animation starts from the current presentation value.
- Enter and exit use the same spatial path.
- No input lockout during transitions.
- Default spring is critically damped; bounce only follows user momentum.
- Reduced Motion uses cross-fade/static state rather than slide, scale, or spring.

### Native macOS fit

- Prefer `NSToolbar`/SwiftUI toolbar, inspector, split view, searchable, standard menus,
  sheets, `NSOpenPanel`/`NSSavePanel`, and semantic controls.
- Commands appear in expected App/File/Edit/View/Window/Help locations.
- Menu items validate against the key window and use standard shortcuts.
- Window frames restore on the current display and remain inside `visibleFrame`.
- AppKit remains the owner of windows; selection remains CALayer-only; agent package
  layering and idle-RAM rules remain intact.

## 9. Release definition

The UX uplift is complete when:

- all P1 findings are closed with automated or recorded evidence;
- no primary surface clips or overlaps at supported minimum sizes or with expanded text;
- every `03-features.md` workflow is keyboard- and VoiceOver-completable;
- Copy, Save, Share, Delete, Discard, and Export have unambiguous object and consequence;
- no user-visible failure is logger-only;
- no interactive target is below 20×20 pt;
- all custom motion/materials pass accessibility variants;
- the editor has standard macOS menus and responsive toolbars;
- Quick Access, History, editor, and studio each pass the usability tasks in D5;
- `make all` passes and GUI/TCC-only checks are documented in the release evidence.
