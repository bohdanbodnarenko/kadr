#!/usr/bin/env bash
# A `catch` in the agent that only logs is a failure the user never hears about
# (docs/18 X-2, docs/04 §5 "Feedback"). This lists every one that is not in
# Scripts/silent-catches.allow, and exits non-zero if there are any.
#
# Allow-list lines are `path|text from the logger.error line|why it is not user-facing`.
# Matching on the message rather than a line number keeps entries valid as files move.
set -euo pipefail

cd "$(dirname "$0")/.."

allow="Scripts/silent-catches.allow"
found=$(find Kadr -name '*.swift' -print0 | xargs -0 awk -f Scripts/silent-catches.awk || true)

violations=0
while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    path="${hit%%:*}"
    allowed=0
    while IFS='|' read -r allowPath allowText _reason; do
        [[ -z "$allowPath" || "$allowPath" == \#* ]] && continue
        if [[ "$path" == "$allowPath" && "$hit" == *"$allowText"* ]]; then
            allowed=1
            break
        fi
    done < "$allow"
    if [[ $allowed -eq 0 ]]; then
        echo "  $hit"
        violations=$((violations + 1))
    fi
done <<< "$found"

if [[ $violations -gt 0 ]]; then
    echo "$violations catch block(s) only log: report through FailurePresenter, or add them to $allow with the reason"
    exit 1
fi
