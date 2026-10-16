#!/usr/bin/env bash
# herd-dashboard.sh <session>
h="$HOME/.claude/herd/$1"
echo "== agenter =="
jq -r '.agents | to_entries[] | "\(.key)\t\(.value.tab_name // "-")\t\(.value.pane_id)\t\(.value.purpose)"' "$h/registry.json" 2>/dev/null |
while IFS=$'\t' read -r id tab pane purpose; do
  st=$(jq -r '"\(.state) \(.at)"' "$h/status/$id.json" 2>/dev/null || echo "-")
  printf '%-16s %-12s %-12s %-28s %s\n' "$id" "$tab" "$pane" "$st" "$purpose"
done
echo; echo "== uppgifter =="
jq -r '.[]? | "\(.id)\t\(.state)\t\(.owner // "-")\t\(.title)"' "$h/tasks.json" 2>/dev/null | column -t -s $'\t'
echo; echo "== senaste meddelanden =="
tail -n 8 "$h/messages.log" 2>/dev/null
