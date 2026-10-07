# Kadr

> **«кадр»** — Ukrainian for *frame, shot*.

A free, open-source, native macOS screen-capture app — the CleanShot X
alternative that costs nothing, sends nothing, and idles under 30 MB.

**Status: internal testing (0.9.0).** Capture, cards, pins, History, the annotation
editor, recording and the studio are all in; a small group of dogfooders is using signed
builds on the beta update channel while the work in
[docs/18-polish-and-ux-review.md](docs/18-polish-and-ux-review.md) lands.
Testers start with [TESTING.md](TESTING.md).

## Install

Download the latest DMG from the
[Releases](https://github.com/bohdanbodnarenko/kadr/releases) page, open it and drag Kadr
into Applications. Kadr updates itself through Sparkle; Settings ▸ Updates has the
switch and a Check Now button. Requires macOS 14 or later on a Mac with Apple silicon. (A Homebrew cask,
`brew install --cask kadr`, follows the first public release.)

## Features

- **Capture:** area with a magnifier loupe and freeze-frame, window, full screen, scrolling
  capture, self-timer, repeat last area, text recognition (OCR) and a colour picker.
- **Quick Access cards:** every capture lands as a card you can drag into any app, copy,
  save, annotate, pin or share.
- **Annotation editor:** arrows, shapes, text, counters, blur and pixelate redaction with
  auto-detection of secrets, crop, beautify backgrounds, and re-editable `.kadr` projects.
- **Recording:** screen, window or area to MP4 or GIF with system audio, microphone,
  camera bubble, click highlights, key overlays and a teleprompter.
- **Studio:** trim and cut, automatic zooms from your clicks, transcription, captions and
  filler-word removal, all on this Mac.
- **History:** a searchable library of past captures, including the text inside them.
- **Automation:** `kadr://` URLs, a `kadr` command-line tool and Shortcuts actions.

## Permissions

Kadr asks for each permission only when you first use the feature that needs it.

| Permission | Why |
|---|---|
| Screen & System Audio Recording | Required: screenshots, recordings and system audio. |
| Microphone | Your voice in a recording, as its own track. |
| Camera | The camera bubble, only while that recording runs. |
| Accessibility | Auto-scroll in scrolling capture; key overlays (with Input Monitoring). |
| Input Monitoring | Clicks and shortcuts for the studio and key overlays — never ordinary typing. |
| Speech Recognition | The teleprompter following your voice, and studio transcription. On-device only. |

Nothing you capture leaves your Mac.

## Principles

Kadr is **100% local**: no accounts, no cloud, no telemetry, no share-by-URL.
Sharing is drag-and-drop and the native macOS share sheet. The only network
traffic is the Sparkle update check and, when you ask for filler-word removal, macOS
installing an on-device speech model — enforced by
`Scripts/check-layering.sh` in CI, so the promise is machine-verified, not a
README claim. Performance is a budget, not a hope: the agent idles < 30 MB
with zero timers, tracked in CI (docs/02-prd.md §8).

## Building

Requires macOS 14+ and the Xcode CI uses (see `.github/workflows/ci.yml`).

```sh
open Kadr.xcworkspace        # open this, not the .xcodeproj
make help                    # every command
make build                   # the agent app
make all                     # lint, every test, layering and size — what CI runs
```

Releases: [Distribution/RELEASING.md](Distribution/RELEASING.md). Contributing:
[CONTRIBUTING.md](CONTRIBUTING.md). Security: [SECURITY.md](SECURITY.md). Changes:
[CHANGELOG.md](CHANGELOG.md).

## Documentation

The full spec lives in [docs/](docs/): product requirements
([PRD](docs/02-prd.md)), detailed [feature specs](docs/03-features.md),
the [architecture](docs/04-swift-architecture.md), the
[competitive analysis](docs/01-competitive-analysis.md), and the
[build sequence](docs/06-implementation-guide.md). [docs/00-README.md](docs/00-README.md)
gives the reading order.

## License

[MIT](LICENSE). The three libraries Kadr ships — Sparkle, KeyboardShortcuts and GRDB.swift
— are MIT too; their notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and in
the app's About panel.
