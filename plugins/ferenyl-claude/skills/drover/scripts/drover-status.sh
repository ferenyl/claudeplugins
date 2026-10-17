#!/usr/bin/env bash
# drover-status.sh <state> <file>  (hook: reads hook JSON from stdin)
# state: busy | idle | blocked | unblock (busy only if currently blocked)
set -euo pipefail
s=$1 f=$2
if [[ $s == unblock ]]; then
  [[ $(jq -r .state "$f" 2> /dev/null) == blocked ]] || { cat > /dev/null; exit 0; }
  s=busy
fi
jq -c --arg s "$s" '{state: $s, session_id, transcript_path, cwd, at: (now | todate)}' > "$f.tmp"
mv "$f.tmp" "$f"
if [[ $s == blocked ]]; then
  id=$(basename "$f" .json) h=$(dirname "$(dirname "$f")")
  [[ $id == drover ]] || echo "[$id -> drover] blocked: needs input/approval" >> "$h/inbox/drover.log"
  command -v notify-send > /dev/null && notify-send "drover: $id blocked" "needs input/approval" || true
fi
