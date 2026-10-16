#!/usr/bin/env bash
# herd-status.sh <state> <file>  (hook: läser hook-JSON från stdin)
set -euo pipefail
jq -c --arg s "$1" '{state: $s, session_id, transcript_path, cwd, at: (now | todate)}' > "$2.tmp"
mv "$2.tmp" "$2"
