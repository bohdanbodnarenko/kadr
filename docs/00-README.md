# Kadr — Documentation Set

> **Kadr** («кадр» — Ukrainian for *frame/shot*) is the chosen name: 4 letters, easy to pronounce ("kah-dr"), and availability-checked against GitHub/App Store screenshot tools (2026-08-27, no collisions found). Namespace: repo `kadr`, `brew install --cask kadr`, CLI `kadr`, URL scheme `kadr://`, bundle ID `app.kadr.Kadr`, project files `.kadr`, domain candidates kadr.app / getkadr.app.
> A free, open-source, native macOS screen-capture app: the CleanShot X / ShotBase alternative that costs nothing, sends nothing, and idles under 30 MB.
> Docs authored 2026-08-26 from primary-source research (vendor sites, changelogs, Apple docs, GitHub repos, HN/Reddit sentiment).

## Reading order

| Doc | What it answers |
|---|---|
| [`01-competitive-analysis.md`](01-competitive-analysis.md) | What CleanShot X and ShotBase actually do (feature-by-feature, with interaction detail), every popular alternative, the full comparison matrix, and where the market gap is |
| [`02-prd.md`](02-prd.md) | Product vision, principles, personas, phased scope (MVP → parity → beyond), CI-enforced performance budgets, risks, open questions |
| [`03-features.md`](03-features.md) | Every feature specified in detail: interaction flows, options, edge cases, acceptance criteria |
| [`04-swift-architecture.md`](04-swift-architecture.md) | The modern Swift architecture: 3-process RAM strategy, SPM module layout, ScreenCaptureKit pipeline, overlay-window recipes, Swift 6.2 concurrency, distribution, decision log |
| [`05-cross-platform-gpui.md`](05-cross-platform-gpui.md) | The gpui/Rust evaluation: framework maturity, crate-by-crate platform matrix, Wayland reality, RAM comparison, and the recommendation |
| [`06-implementation-guide.md`](06-implementation-guide.md) | The build plan: 25 milestones in dependency order, each with a paste-ready AI coding prompt and "done when" acceptance checks, plus the repo `CLAUDE.md` template |
| [`07-code-review-2026-08.md`](07-code-review-2026-08.md) | Code review of the implemented M0–M18 codebase: 3 critical, 6 high, 11 medium findings with file:line, plus the compliance scorecard |
| [`08-screendrop-analysis.md`](08-screendrop-analysis.md) | Source-level study of Screendrop (CC0): what it does better, what we keep, the license caution on its tldraw-derived `Engine/`, and the ranked steal list |
| [`09-uplift-plan.md`](09-uplift-plan.md) | The post-M18 roadmap: Sprint U0 (fixes) → U1 (editor uplift) → U2 (UX) → U3 (recording studio), superseding docs/06 ordering for remaining work |
| [`10-road-to-v1.md`](10-road-to-v1.md) | Post-U3 review and the road to v1.0: sprints R0 (correctness — the studio telemetry chain is inert) → R1 (performance) → R2 (memory + CI gates) → R3 (polish), plus the two governance decisions |
| [`11-shipping-v1.md`](11-shipping-v1.md) | **Current plan.** Post-R review: the telemetry seam is mirrored and doubled; sprints S0 (ship-blockers) → S1 (make the gates real and green) → S2 (finish the partials) → S3 (real-device validation and launch) |

## The five decisions that matter (summary)

1. **macOS-first, native Swift** (macOS 14+, Swift 6.2 strict concurrency). Every winning app in this category is native and macOS-only; the requirement "max performance, min background RAM" is structurally easiest to hit with AppKit. gpui/Rust is re-evaluated at gpui 1.0; until then cross-platform is hedged by keeping core logic UI-free (doc 05 §7).
2. **Three-process design is the RAM strategy:** a tiny AppKit `NSStatusItem` agent (< 30 MB idle, zero timers), a separate editor app that dies on close, and a self-terminating XPC helper for Vision/encoders — process exit is the garbage collector (doc 04 §1).
3. **The Quick Access Overlay is the product:** capture → floating thumbnail → drag into any app. CleanShot's most-loved interaction, absent from all OSS tools (docs 01 §7, 03 §2).
4. **Differentiate on:** performance budgets published & CI-enforced; a **100% local, zero-network app** (no hosting, no share-by-URL — sharing is drag-and-drop and the native share sheet, and CI verifies no networking code exists outside Sparkle); a first-class CleanShot-grade editor; OCR-searchable local history; and Shottr-style pixel ruler + OKLCH color tools (doc 02 §5).
5. **MIT license, Developer ID signed + notarized, Sparkle updates, Homebrew cask** — the trust infrastructure OSS competitors skip (doc 02 §9).

## Phase snapshot

- **P1 (3 mo):** area/window/fullscreen capture with freeze-frame + magnifier, Quick Access Overlay, annotation editor v1, OCR, pinning, hotkeys, notarized DMG.
- **P2 (mo 4–8):** recording (MP4/GIF, system audio, click/keystroke viz), scrolling capture, history, beautify, auto-redaction, URL scheme + CLI.
- **P3 (mo 9+):** OCR-searchable history, pixel ruler + color picker, editor depth (background removal, multi-image composition, re-editable project files).
