# Changelog

What changed in each Kadr build, newest first. Release notes in Sparkle
(`<sparkle:releaseNotesLink>`) point at a section of this file.

Builds are numbered `<version> (<build> · <commit>)`, the same string Settings ▸ Updates
shows and a bug report asks for.

## Unreleased — 0.9.0 (internal testing)

The first build for dogfooders (docs/17).

### Added
- Help ▸ **Report a Problem…** and **Export Diagnostics…**: a local zip of Kadr's logs,
  crash and hang reports and a system summary, revealed in Finder. Nothing is sent.
- Local crash and hang capture through MetricKit.
- A **beta** update channel, on by default for dogfood builds.
- The build number and commit in Settings ▸ Updates and the About panel, with a Copy button.
- `Scripts/uninstall.sh`, and Settings ▸ Advanced ▸ **Remove All Kadr Data…**, for a clean slate.
- `TESTING.md` for testers.

### Fixed
- The app menu's Settings…, Kadr Help and Keyboard Shortcuts did nothing.
- Update checks could not find the feed: its URL never reached the built app.
- Release builds lost the camera and microphone entitlements when re-signed.

### Changed
- Version 0.9.0; the build number now increases with every commit.
