# Contributing to Kadr

Thanks for helping. Kadr is a native macOS screen-capture app with two promises it does
not bend: nothing you capture leaves your Mac, and the menu-bar agent idles under 30 MB
with no timers. The rules that keep those promises are in [CLAUDE.md](CLAUDE.md); they
apply to people too.

## Before you start

- Read [docs/00-README.md](docs/00-README.md) for the reading order. `docs/03` defines
  behaviour, `docs/04` structure, and `docs/17` is the current plan.
- Open an issue before a large change, so we can agree it matches the spec.

## Building and checking

Requires macOS 14+ and the Xcode named in `.github/workflows/ci.yml`.

```sh
make help            # every command
make build           # the agent app
make test            # every package's tests, then the app's
make lint check      # SwiftLint, SwiftFormat, layering, zero-network and size
```

`make all` is what CI runs. A pull request should pass it locally.

## Writing user-visible text

Follow the vocabulary in `docs/03-features.md` (the preamble), summarised here so a reviewer can point at it.

User-visible text follows these rules. Code identifiers and comments may keep older names.

- **Spelling:** US English (`color`, `center`, `recognize`, `gray`, `canceled`). The development language is `en`.
- **Capture island:** the floating panel that opens from the menu bar and ⇧⌘2. Not "All-in-One", "HUD" or "strip".
- **Card:** one capture shown after it is taken. **Quick Access** is the feature that shows cards. **Overlay** means only things drawn onto a recording (click, key and webcam overlays). The surface you drag on to select an area is the **selection screen**.
- **History:** the list of past captures, everywhere. Not "library".
- **Labels:** Show in Finder · Got It · Install Speech Model… · System audio · Restart. Buttons use Title Case.
- **Removing things:**
  - **Move to Trash** when the file goes to the Trash.
  - **Discard** for an unsaved take or unsaved changes.
  - **Remove** for a reference, a setting or an item in a list; the file stays.
  - **Delete** only when the data is gone for good.
- **Counts:** write whole sentences per count, or use automatic grammar agreement (`^[\(n) item](inflect: true)`). Never splice "s" onto a word in code.

## What a good pull request has

- One topic. Small commits with plain, descriptive messages.
- Tests: pure packages get unit tests; geometry and parsers are table-driven; a bug fix
  gets a regression test at the seam where the bug lived.
- No new networking. The only exceptions are listed in CLAUDE.md rule 1 and enforced by
  `Scripts/check-layering.sh`.
- No new dependencies without a justification against docs/04 §12.
- Any spec ambiguity you resolved, written in the PR description.

## Licences

Kadr is MIT. Code under AGPL or BUSL (for example QuickRecorder or Capso) may be read for
reference but never copied.

## Reporting a bug

Use Help ▸ Report a Problem… in the app; see [TESTING.md](TESTING.md). For security
issues, see [SECURITY.md](SECURITY.md).
