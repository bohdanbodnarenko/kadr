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

size_kb=$(du -sk "$app" | cut -f1)
size_mb=$((size_kb / 1024))
budget_kb=$((BUDGET_MB * 1024))

printf '  bundle: %s\n  size:   %s MB (%s KB)\n  budget: %s MB (PRD §8)\n' \
    "$app" "$size_mb" "$size_kb" "$BUDGET_MB"

if [ "$size_kb" -gt "$budget_kb" ]; then
    printf '\033[0;31m✘ app bundle is over the PRD §8 budget\033[0m\n'
    exit 1
fi
printf '\033[0;32m✔ app bundle is within the PRD §8 budget\033[0m\n'
