#!/bin/bash
#
# Public API that tests mention but production never calls is a defect marker
# (docs/10 R3.3): the helper was written for a consumer that was then implemented
# differently, and in several cases the dead helper was the correct one.
#
# Two checks:
#   1. Symbols deleted in R3.3 must not reappear as public API.
#   2. Public members whose name appears in Tests but not in production (Kadr/,
#      KadrEditor/, HelperTools/, KadrCLI/, Packages/*/Sources) fail unless they
#      are on the allowlist.
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

failures=0
fail() { printf '%s✘ %s%s\n' "$RED" "$1" "$OFF"; failures=$((failures + 1)); }
pass() { printf '%s✔ %s%s\n' "$GREEN" "$1" "$OFF"; }

# ---------------------------------------------------------------- 1. deleted symbols
DELETED_PATTERNS=(
    'public static func isBound'
    'public var isCurved'
    'public var capturesClicks'
    'public var limitation'
    'public func committedEdit'
    'public var isExportUpToDate'
    'public var isReady'
    'public var canInstall'
    'public static let keepForever'
    'public var isAxisAligned'
    'public var isPointerTool'
    'public func legacyAction'
    'var insertedImages'
    # docs/11 S2: the window-geometry history. R3.1 replaced it with normalise-at-capture
    # and left the old pipeline running beside its replacement — collected, copied into the
    # sidecar, rebased on every edit change and persisted, and read by nothing.
    'public var windowGeometry'
    'struct WindowGeometrySample'
    'struct WindowGeometryTracker'
)

prod_sources=$(find Packages/*/Sources Kadr KadrEditor HelperTools KadrCLI -name '*.swift' 2>/dev/null | sort)
deleted_hits=""
while IFS= read -r file; do
    [ -z "$file" ] && continue
    for pattern in "${DELETED_PATTERNS[@]}"; do
        hit=$(grep -nF "$pattern" "$file" 2>/dev/null) || true
        [ -n "$hit" ] && deleted_hits="${deleted_hits}${file}: ${hit}"$'\n'
    done
done <<< "$prod_sources"

if [ -n "$deleted_hits" ]; then
    fail "deleted public API from docs/10 R3.3 has come back"
    printf '%s' "$deleted_hits" | sed 's/^/    /'
else
    pass "deleted R3.3 public API has not come back"
fi

# ---------------------------------------------------------------- 2. tested-only public symbols
ALLOWLIST=Scripts/dead-api-allowlist.txt
allowed() {
    local name="$1"
    [ -f "$ALLOWLIST" ] && grep -qxF "$name" "$ALLOWLIST"
}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# One blob each, so each name is two greps against concatenated text instead of
# a walk of the tree.
#
# Comments are stripped from the production blob (docs/11 S2). They were not, so a symbol
# mentioned in its own doc comment counted as its own caller — which is exactly how
# `renderStamp` stayed green with zero production callers, and it is a hole that widens as
# the codebase gets better commented. This deliberately also cuts a `//` inside a string
# literal, which can only *lower* a count and so can only make this stricter: a false
# alarm somebody sees and answers, rather than a silence nobody can.
: > "$scratch/prod"
while IFS= read -r file; do
    [ -f "$file" ] && sed -E 's@//.*$@@' "$file" >> "$scratch/prod"
done <<< "$prod_sources"
: > "$scratch/tests"
find Packages/*/Tests KadrTests -name '*.swift' 2>/dev/null | while IFS= read -r file; do
    cat "$file" >> "$scratch/tests"
done

: > "$scratch/names"
find Packages/*/Sources -name '*.swift' -not -name '*Module.swift' 2>/dev/null \
    | while IFS= read -r file; do
        # Any indentation, not exactly four spaces (docs/11 S2). A member of a nested type
        # is indented eight and was simply never scanned.
        # The `sed` is anchored at the declaration rather than searching for the keyword
        # with `\b` (docs/11 S2). BSD `sed -E` does not implement `\b`, so on macOS the old
        # pattern matched nothing at all and the name list came out *empty* — this whole
        # check has been passing vacuously over zero symbols. Anchoring needs no word
        # boundary and behaves the same on both seds.
        grep -E '^[[:space:]]+public (static )?(mutating )?(func|var|let) ' "$file" \
            | grep -vE ' public (static )?(mutating )?func init' \
            | sed -E 's/^[[:space:]]+public (static )?(mutating )?(func|var|let) +([A-Za-z_][A-Za-z0-9_]*).*/\4/'
    done \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
    | sort -u > "$scratch/names"

tested_only=""
while IFS= read -r name; do
    [ -z "$name" ] && continue
    allowed "$name" && continue
    # Four, not eight (docs/11 S2). The old floor silently exempted every short name, and
    # short names are not less likely to be dead. Below four is `id`, `url` and friends,
    # where the noise genuinely does outweigh the signal.
    [ ${#name} -lt 4 ] && continue
    grep -qwF "$name" "$scratch/tests" || continue
    # Whole identifiers, not substrings (docs/11 S2). This is what hid `renderStamp`: the
    # session also has a `renderStampURL`, so a substring count found "two callers" for a
    # symbol with none. One occurrence is the definition; two means a real caller.
    count=$(grep -owF "$name" "$scratch/prod" | wc -l | tr -d ' ')
    if [ "${count:-0}" -le 1 ]; then
        tested_only="${tested_only}  ${name}"$'\n'
    fi
done < "$scratch/names"

if [ -n "$tested_only" ]; then
    fail "public API with tests but no production caller (docs/10 R3.3)"
    printf '%s' "$tested_only"
    printf '    add a genuine caller, delete the symbol, or list it in %s\n' "$ALLOWLIST"
else
    pass "no unallowlisted tested-only public API"
fi

if [ "$failures" -eq 0 ]; then
    exit 0
fi
exit 1
