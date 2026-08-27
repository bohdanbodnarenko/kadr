#!/bin/bash
#
# Kadr — app bundle size budget (PRD §8: "App bundle size — < 15 MB DMG").
#
# Stub for M0.1: it measures the built .app. The DMG-level check lands with the
# packaging work in M11; until then the .app is the closest available proxy and
# the budget is deliberately the same number, so the check only gets stricter.
#
# Usage:
#   Scripts/check-size.sh [path/to/Kadr.app]
#   KADR_APP=/path/to/Kadr.app Scripts/check-size.sh
#
# Exits 0 (with a note) when there is no build product to measure, so it is safe
# to run before a build; pass --require-build to make a missing product fail.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BUDGET_MB=15
require_build=0
app=""

for arg in "$@"; do
    case "$arg" in
        --require-build) require_build=1 ;;
        *) app="$arg" ;;
    esac
done

[ -z "$app" ] && app="${KADR_APP:-}"

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

raw_kb=$(du -sk "$app" | cut -f1)

# The budget is about the DMG, and a DMG contains the archived app with its debug symbols
# moved into a dSYM. A plain `xcodebuild build` product still carries them, so measuring
# it directly overstates the shipped size by a couple of megabytes. Strip a copy and
# measure that: same bytes the user downloads.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/" 2>/dev/null
stripped="$staging/$(basename "$app")"
find "$stripped" -type f -perm +111 -print0 2>/dev/null | while IFS= read -r -d '' binary; do
    file "$binary" 2>/dev/null | grep -q "Mach-O" && strip -S "$binary" 2>/dev/null
done

size_kb=$(du -sk "$stripped" | cut -f1)
size_mb=$((size_kb / 1024))
budget_kb=$((BUDGET_MB * 1024))
headroom_kb=$((budget_kb - size_kb))

printf '  bundle: %s\n  shipped size: %s MB (%s KB, stripped)\n  build size:   %s MB (with symbols)\n  budget: %s MB (PRD §8)\n' \
    "$app" "$size_mb" "$size_kb" "$((raw_kb / 1024))" "$BUDGET_MB"

if [ "$size_kb" -gt "$budget_kb" ]; then
    printf '\033[0;31m✘ app bundle is over the PRD §8 budget\033[0m\n'
    exit 1
fi
# Below a megabyte of headroom, the next feature is the one that breaks the budget.
if [ "$headroom_kb" -lt 1024 ]; then
    printf '\033[0;33m▲ within budget, but only %s KB of headroom left\033[0m\n' "$headroom_kb"
    exit 0
fi
printf '\033[0;32m✔ app bundle is within the PRD §8 budget (%s KB to spare)\033[0m\n' "$headroom_kb"
