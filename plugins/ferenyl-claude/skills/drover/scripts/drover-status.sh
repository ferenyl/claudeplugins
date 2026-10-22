#!/usr/bin/env bash
# drover-status.sh <state> <file>  (hook: reads hook JSON from stdin)
# state: busy | idle | blocked | unblock (busy only if currently blocked)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
s=$1 f=$2
t0=$(date +%s%N) # event order: a hook process that lost the race must not overwrite a later event
id=$(basename "$f" .json) h=$(dirname "$(dirname "$f")")
if [[ $s == unblock ]]; then
  [[ $(jq -r .state "$f" 2> /dev/null) == blocked ]] || { cat > /dev/null; exit 0; }
  s=busy
fi
# one writer per status file: the previous state comes out of the lock, the new one goes in via a private temp file
ps=$(
  exec 8> "$f.lock"
  flock 8
  p=$(jq -ce '[.state, .since, (.ts // 0), .session_id, .transcript_path, .cwd]' "$f" 2> /dev/null) || p='[null,null,0,null,null,null]'
  if [[ $s != blocked ]] && (($(jq -r '.[2]' <<< "$p") > t0)); then echo stale; exit 0; fi # a later event is already recorded
  t=$(mktemp "$f.XXXXXX")
  if jq -c --arg s "$s" --argjson p "$p" --argjson ts "$t0" \
    '{state: $s, session_id: (.session_id // $p[3]), transcript_path: (.transcript_path // $p[4]), cwd: (.cwd // $p[5]), at: (now | todate), ts: $ts,
      since: (if $p[0] == $s and $p[1] then $p[1] else (now | todate) end)}' > "$t"; then mv "$t" "$f"; else rm -f "$t"; fi
  jq -r '.[0] // empty' <<< "$p"
)
[[ $ps != stale ]] || exit 0 # no side effects for a discarded event
hid=$(basename "$h")
if [[ $s == busy && $ps == blocked && -s $h/queue/$id.txt ]]; then # nothing flushes queued messages by itself
  echo "[drover-sh -> drover] $id unblocked, $(wc -l < "$h/queue/$id.txt") queued message(s): drover.sh flush $hid $id" >> "$h/inbox/drover.log"
fi
if [[ $s == idle && $ps != idle && $id != drover && -f $h/tasks.json ]]; then # a Stop without a report leaves the drover waiting
  rat=$(jq -r '.at // empty' "$h/reports/$id.json" 2> /dev/null || true)
  # an answered question is not a report
  if [[ $(jq -r .status "$h/reports/$id.json" 2> /dev/null) == question ]] && ! jq -e --arg a "$id" 'any(.[]?; .agent == $a)' "$h/questions.json" > /dev/null 2>&1; then rat=; fi
  for tid in $(jq -r --arg o "$id" --arg r "$rat" '.[]? | select(.owner == $o and .state == "in_progress" and ($r < (.started_at // ""))) | .id' "$h/tasks.json" 2> /dev/null || true); do
    w="[drover-sh -> drover] $id idle, task $tid has no report"
    tail -n 50 "$h/inbox/drover.log" 2> /dev/null | grep -qxF "$w" || echo "$w" >> "$h/inbox/drover.log" # once per task
  done
fi
if [[ $s == blocked ]]; then
  [[ $id == drover ]] || echo "[$id -> drover] blocked: needs input/approval" >> "$h/inbox/drover.log"
  notify "drover: $id blocked" "needs input/approval"
fi
# story mode: blocked/unblocked agents move their stories in and out of waiting-for-user
[[ $1 == busy || ! -f $h/stories.json ]] || "$(dirname "$0")/drover-story.sh" "$(basename "$h")" derive > /dev/null 2>&1 || true
