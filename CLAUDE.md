# Kadr — agent rules

You are working on Kadr, a free open-source native macOS screen-capture
app. The specs in docs/ are authoritative: 02=PRD, 03=feature specs (behavior
+ acceptance criteria), 04=architecture (module layout, recipes, decision log).
When a task references a doc section, read it before writing code.

## Non-negotiable rules
1. ZERO NETWORK: no import Network, no URLSession, no sockets anywhere except
   the Sparkle update integration. There are no upload/share/URL features —
   sharing is drag-and-drop + NSSharingServicePicker only. CI enforces this.
2. RAM budget: agent idles <30 MB, zero timers, 0.0% CPU. The agent never
   links EditorUI or VisionServices. Vision/encoders run in HelperTools
   (self-terminating XPC); the editor is a separate app that dies on close.
3. All screen capture via ScreenCaptureKit only — never CGWindowListCreateImage
   or CGDisplayCreateImage. All SCK calls stay in the agent process (TCC).
4. AppKit owns windows (NonActivatingPanel recipes in docs/04 §5); SwiftUI is
   allowed only inside NSHostingView content that is deallocated on close.
   Nothing SwiftUI in the selection overlay's mouse path — CALayer only.
5. Swift 6 language mode, strict concurrency, no new DispatchQueues outside
   SCK-required handler queues. @MainActor UI, actors for engines,
   AsyncStream at delegate boundaries.
6. Coordinates go through Shared.Geometry typed wrappers (ScreenPoint,
   PixelRect) — never raw CGRect math across the AppKit/CG flip or
   point/pixel scaling.
7. Every user-visible behavior must match docs/03; if a spec is ambiguous,
   note the interpretation in the PR description rather than inventing UI.
8. Add os_signpost to any path with a PRD §8 budget; never remove one.
9. Tests: pure packages get unit tests with real coverage; geometry and
   parsers are table-driven; perf budgets are tests, not comments.
10. Dependencies: additions require justification against docs/04 §12;
    KeyboardShortcuts and Sparkle and GRDB are pre-approved. AGPL/BUSL code
    (QuickRecorder, Capso) is READ-ONLY reference — never copy it.

## Workflow
- One milestone per branch (docs/06 defines them). Run swiftlint,
  swiftformat, Scripts/check-layering.sh, and package tests before declaring
  done. Verify the milestone's "Done when" list and say which items you
  could not verify in-sandbox (e.g., TCC-gated integration tests).

## Repo layout (as of M0.1)

```
Kadr.xcworkspace          open this, not the .xcodeproj
Kadr.xcodeproj            the agent app target `Kadr` (LSUIElement, macOS 14+)
Kadr/                     agent app sources (AppKit shell only)
KadrTests/                agent app unit tests
Packages/<Module>/        13 local SPM packages, docs/04 §2
Scripts/                  check-layering.sh, check-size.sh
.github/workflows/ci.yml  packages (matrix) · app build · lint + checks
```

### Package layering (docs/04 §2)

A package may only depend on packages in a strictly lower layer. This is
enforced by `Scripts/check-layering.sh` and by the module tests.

| Layer | Packages | Depends on |
|---|---|---|
| 0 | Shared | — |
| 1 | CaptureCore, OverlayKit, AnnotationModel, MediaExport, VisionServices, AutomationKit, SettingsKit | Shared |
| 2 | RecordingCore (CaptureCore), SelectionUI (OverlayKit), AnnotationRender (AnnotationModel), HistoryKit (MediaExport) | Shared + the package in brackets |
| 3 | EditorUI | Shared, AnnotationModel, AnnotationRender, MediaExport |

The agent app target links every package **except** EditorUI (editor app) and
VisionServices (XPC helper) — rule 2 above, checked by CI.

## Commands

`make help` lists them. The Makefile is the single definition — CI runs the same targets,
so a command that passes there is the command you ran.

```sh
make build           # build the agent app
make test            # every package's tests, then the app's
make lint check      # swiftlint, swiftformat, layering, size
make install         # build signed and install into /Applications
make all             # what CI runs
```

One package at a time: `make test-package PACKAGE=Shared`.

Do not add a command here that is not a target. Four copies of the build line — this file,
`ci.yml`, and whatever was in a shell history — is how they drift.
