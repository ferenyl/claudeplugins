#!/usr/bin/env bash
# herd-send.sh <session> <to-id|orchestrator> <from-id> <message...>
set -euo pipefail
s=$1 to=$2 from=$3; shift 3
msg="$*"
h="$HOME/.claude/herd/$s"
line="$(date -Is) [$from -> $to] $msg"

if [[ $to == orchestrator ]]; then
  echo "$line" >> "$h/inbox/orchestrator.log"
else
  pane=$(jq -r --arg a "$to" '.agents[$a].pane_id // empty' "$h/registry.json")
  [[ -n $pane ]] || { echo "okänd agent: $to" >&2; exit 1; }
  zellij -s "$s" action paste -p "$pane" "[från $from] $msg"
  zellij -s "$s" action send-keys -p "$pane" Enter
fi
echo "$line" >> "$h/messages.log"
