# Kadr

> **«кадр»** — Ukrainian for *frame, shot*.

A free, open-source, native macOS screen-capture app — the CleanShot X
alternative that costs nothing, sends nothing, and idles under 30 MB.

**Status: pre-alpha.** The scaffolding (M0) is done; capture features are
landing milestone by milestone — see [docs/06-implementation-guide.md](docs/06-implementation-guide.md).

## Principles

Kadr is **100% local**: no accounts, no cloud, no telemetry, no share-by-URL.
Sharing is drag-and-drop and the native macOS share sheet. The only network
call the app will ever make is the Sparkle update check — enforced by
`Scripts/check-layering.sh` in CI, so the promise is machine-verified, not a
README claim. Performance is a budget, not a hope: the agent idles < 30 MB
with zero timers, tracked in CI (docs/02-prd.md §8).

## Building

Requires Xcode 16+ on macOS 14+.

```sh
open Kadr.xcworkspace        # open this, not the .xcodeproj
# or:
xcodebuild -workspace Kadr.xcworkspace -scheme Kadr build
```

Checks that CI runs: `swiftlint lint --strict`, `swiftformat --lint .`,
`Scripts/check-layering.sh`, `Scripts/check-size.sh`, and `swift test` in
every package under `Packages/`.

## Documentation

The full spec lives in [docs/](docs/): product requirements
([PRD](docs/02-prd.md)), detailed [feature specs](docs/03-features.md),
the [architecture](docs/04-swift-architecture.md), the
[competitive analysis](docs/01-competitive-analysis.md), and the
[build sequence](docs/06-implementation-guide.md).

## License

[MIT](LICENSE).
