#!/bin/bash
#
# Kadr — keep the string catalogs in step with the source (docs/18 X-4).
#
# Xcode syncs a String Catalog only when a build runs inside the IDE. A command-line
# build emits the extracted strings (`.stringsdata`, one per source file) but leaves the
# catalog alone, so a renamed or new string reached the app untranslatable and nothing
# said so. This runs the same sync Xcode would, from the strings the last build emitted.
#
# Usage:
#   Scripts/sync-strings.sh           rewrite the catalogs
#   Scripts/sync-strings.sh --check   fail if a sync would change them (CI)
#
# Run after `make build` and `make build-editor`: the strings come from those builds.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

check=false
[[ "${1:-}" == "--check" ]] && check=true

intermediates="${KADR_INTERMEDIATES:-build/Build/Intermediates.noindex/Kadr.build/Debug}"
status=0

# catalog : the target whose build emitted its strings
for pair in "Kadr/Localizable.xcstrings:Kadr.build" "KadrEditor/Localizable.xcstrings:KadrEditor.build"; do
    catalog="${pair%%:*}"
    target="${pair##*:}"
    stringsdata=()
    while IFS= read -r file; do
        stringsdata+=(--stringsdata "$file")
    done < <(find "$intermediates/$target" -name '*.stringsdata' 2>/dev/null)

    if [[ ${#stringsdata[@]} -eq 0 ]]; then
        echo "✘ no extracted strings for $catalog — build $target first" >&2
        status=1
        continue
    fi

    if $check; then
        scratch="$(mktemp -d)"
        cp "$catalog" "$scratch/Localizable.xcstrings"
        xcrun xcstringstool sync "$scratch/Localizable.xcstrings" "${stringsdata[@]}" >/dev/null
        if ! cmp -s "$catalog" "$scratch/Localizable.xcstrings"; then
            echo "✘ $catalog is out of date with the source — run \`make strings\` and commit it" >&2
            diff <(xcrun xcstringstool print "$catalog" 2>/dev/null | sort) \
                <(xcrun xcstringstool print "$scratch/Localizable.xcstrings" 2>/dev/null | sort) | head -40 >&2
            status=1
        else
            echo "✔ $catalog matches the source"
        fi
        rm -rf "$scratch"
    else
        xcrun xcstringstool sync "$catalog" "${stringsdata[@]}"
        echo "synced $catalog"
    fi
done

exit $status
