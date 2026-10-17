#!/usr/bin/env bash
# drover-title.sh <transcript> <session-id> <title> — append one custom-title line (single O_APPEND write, never rewrites).
set -uo pipefail
t=${1:-} i=${2:-} n=${3:-}
[[ -n $t && -n $i && -n $n && -f $t ]] || exit 1
line=$(jq -nc --arg n "$n" --arg i "$i" '{type: "custom-title", customTitle: $n, sessionId: $i}') || exit 1
printf '%s\n' "$line" >> "$t"
