#!/usr/bin/env bash
# drover-status.sh <state> <file>  (hook: reads hook JSON from stdin)
# state: busy | idle | blocked | unblock (busy only if currently blocked)
set -euo pipefail
s=$1 f=$2
id=$(basename "$f" .json) h=$(dirname "$(dirname "$f")")
if [[ $s == unblock ]]; then
  [[ $(jq -r .state "$f" 2> /dev/null) == blocked ]] || { cat > /dev/null; exit 0; }
  s=busy
fi
jq -c --arg s "$s" '{state: $s, session_id, transcript_path, cwd, at: (now | todate)}' > "$f.tmp"
mv "$f.tmp" "$f"
if [[ $s == blocked ]]; then
  [[ $id == drover ]] || echo "[$id -> drover] blocked: needs input/approval" >> "$h/inbox/drover.log"
  command -v notify-send > /dev/null && notify-send "drover: $id blocked" "needs input/approval" || true
fi
# story mode: blocked/unblocked agents move their stories in and out of waiting-for-user
[[ $1 == busy || ! -f $h/stories.json ]] || "$(dirname "$0")/drover-story.sh" "$(basename "$h")" derive > /dev/null 2>&1 || true
