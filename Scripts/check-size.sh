#!/bin/bash
#
# Kadr — app bundle size budget (PRD §8: "App bundle size — < 15 MB DMG").
#
# The budget is about the DMG the user downloads, so the artefact has to be the one
# that ships: the app out of an `xcodebuild archive`, packed into a UDZO disk image,
# the same compressed format `create-dmg` produces in Scripts/release.sh.
#
# An archive is not the same thing as a `xcodebuild build` product with `strip -S`
# run over it, which is what this script used to measure. Measured on the same tree:
# the archived agent binary is 13.2 MB and the built-then-stripped one is 25.0 MB,
# because `-S` removes debug symbols and leaves every local symbol behind, and
# because an archive compiles whole-module and post-processes. That gap reported a
# 16 MB download against a 15 MB budget for a release that actually ships at 12.9 MB
# — a red gate for a problem nobody had, which is how a gate stops being believed.
#
# So: an archive is measured and can fail the budget. A plain build product is
# measured too, because it is what somebody has to hand mid-change and a regression
# usually shows up there first, but it is reported as an upper bound and does not
# fail — `make size-gate` builds the archive when the real answer is wanted.
#
# Usage:
#   Scripts/check-size.sh [path/to/Kadr.app | path/to/Kadr.xcarchive]
#   KADR_APP=/path/to/Kadr.app Scripts/check-size.sh
#
# Exits 0 (with a note) when there is no build product to measure, so it is safe
# to run before a build; pass --require-build to make a missing product fail.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BUDGET_MB=15
require_build=0
app=""
is_archive=0

for arg in "$@"; do
    case "$arg" in
        --require-build) require_build=1 ;;
        *) app="$arg" ;;
    esac
done

[ -z "$app" ] && app="${KADR_APP:-}"

# An `.xcarchive` was passed (or found): the app inside it is the shipped one.
if [ -n "$app" ] && [ -d "$app/Products/Applications" ]; then
    app=$(find "$app/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
    is_archive=1
fi

if [ -z "$app" ]; then
    # An archive from an older commit is passed over for a current build product rather
    # than failing the run: `make size-gate` rebuilds it when the real answer is wanted.
    head_commit_time=$(git log -1 --format=%ct 2>/dev/null || echo 0)
    for candidate in build/Kadr.xcarchive/Products/Applications/Kadr.app; do
        [ -d "$candidate" ] || continue
        [ "$(stat -f %m "$candidate/Contents/MacOS/Kadr" 2>/dev/null || echo 0)" -ge "$head_commit_time" ] || continue
        app="$candidate" && is_archive=1 && break
    done
fi

if [ -z "$app" ]; then
    # Prefer a local build directory, then the most recent DerivedData product.
    for candidate in build/Build/Products/Release/Kadr.app build/Build/Products/Debug/Kadr.app; do
        [ -d "$candidate" ] && app="$candidate" && break
    done
fi

if [ -z "$app" ]; then
    app=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -type d -name 'Kadr.app' \
        -path '*/Build/Products/*' 2>/dev/null | head -1)
fi

if [ -z "$app" ] || [ ! -d "$app" ]; then
    if [ "$require_build" -eq 1 ]; then
        echo "✘ no Kadr.app found to measure (build first, or pass a path)"
        exit 1
    fi
    echo "• no Kadr.app found — size check skipped (build first, or pass a path)"
    exit 0
fi

# A product older than the checked-out commit measures some other tree: on 2026-09-24
# this gate read a four-week-old archive and reported 2 MB of headroom nobody had checked
# (docs/17 T-REL-8). A stale product fails; a missing one is still only skipped above.
head_time=$(git log -1 --format=%ct 2>/dev/null || echo 0)
binary="$app/Contents/MacOS/Kadr"
[ -f "$binary" ] || binary="$app"
product_time=$(stat -f %m "$binary" 2>/dev/null || echo 0)
if [ "$product_time" -lt "$head_time" ]; then
    printf '\033[0;31m✘ %s is older than HEAD — build first (`make build`, or `make size-gate`\n' "$app"
    printf '  for the archive), or pass the path of a current product\033[0m\n'
    exit 1
fi

raw_kb=$(du -sk "$app" | cut -f1)

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/" 2>/dev/null
stripped="$staging/$(basename "$app")"

# An archive is already post-processed; anything else gets stripped the way one would
# be. `-S -x` rather than `-S`: debug symbols *and* local symbols, which is the pair
# that took the agent binary from 29 MB to 15 MB. It is still an overestimate, because
# an archive also compiles whole-module.
if [ "$is_archive" -eq 0 ]; then
    find "$stripped" -type f -perm +111 -print0 2>/dev/null | while IFS= read -r -d '' binary; do
        file "$binary" 2>/dev/null | grep -q "Mach-O" && strip -S -x "$binary" 2>/dev/null
    done
fi

stripped_kb=$(du -sk "$stripped" | cut -f1)

# The shipped artefact is a compressed disk image, so measure one. UDZO is what
# create-dmg produces in Scripts/release.sh, so this is the download size.
image="$staging/kadr-size-check.dmg"
if hdiutil create -quiet -srcfolder "$staging" -volname "Kadr" -format UDZO \
    -ov "$image" >/dev/null 2>&1 && [ -f "$image" ]; then
    size_kb=$(du -sk "$image" | cut -f1)
    measured="DMG (UDZO, as shipped)"
else
    # No disk-image support (a restricted CI container): fall back to the stripped
    # bundle, which is strictly larger, so the check only gets stricter.
    size_kb="$stripped_kb"
    measured="stripped bundle — hdiutil unavailable, so this is an overestimate"
fi

size_mb=$((size_kb / 1024))
budget_kb=$((BUDGET_MB * 1024))
headroom_kb=$((budget_kb - size_kb))

if [ "$is_archive" -eq 1 ]; then
    kind="archive — the artefact that ships"
else
    kind="build product — an upper bound, not the shipped size"
fi

printf '  bundle: %s\n  measured: %s\n  download size: %s MB (%s KB) — %s\n  stripped .app: %s MB\n  built .app:    %s MB (before stripping)\n  budget: %s MB (PRD §8)\n' \
    "$app" "$kind" "$size_mb" "$size_kb" "$measured" "$((stripped_kb / 1024))" "$((raw_kb / 1024))" "$BUDGET_MB"

if [ "$size_kb" -gt "$budget_kb" ]; then
    if [ "$is_archive" -eq 0 ]; then
        printf '\033[0;33m▲ over the budget, but this is a build product and overstates the\n'
        printf '  shipped size. Run `make size-gate` to measure the archive.\033[0m\n'
        exit 0
    fi
    printf '\033[0;31m✘ the download is over the PRD §8 budget\033[0m\n'
    exit 1
fi
# Below a megabyte of headroom, the next feature is the one that breaks the budget.
if [ "$headroom_kb" -lt 1024 ]; then
    printf '\033[0;33m▲ within budget, but only %s KB of headroom left\033[0m\n' "$headroom_kb"
    exit 0
fi
printf '\033[0;32m✔ the download is within the PRD §8 budget (%s KB to spare)\033[0m\n' "$headroom_kb"
