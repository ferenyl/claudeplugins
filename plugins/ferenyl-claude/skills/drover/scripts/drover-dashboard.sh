#!/usr/bin/env bash
# drover-dashboard.sh <drover-id>
h="$HOME/.claude/drover/$1"
echo "== $(jq -r .session "$h/registry.json" 2>/dev/null) =="
echo "== agents =="
jq -r '.agents | to_entries[] | "\(.key)\t\(.value.model // "-")\t\(.value.tab_name // "-")\t\(.value.pane_id)\t\(.value.purpose)"' "$h/registry.json" 2>/dev/null |
while IFS=$'\t' read -r id model tab pane purpose; do
  st=$(jq -r '"\(.state) \(.at)"' "$h/status/$id.json" 2>/dev/null || echo "-")
  printf '%-16s %-8s %-12s %-12s %-28s %s\n' "$id" "$model" "$tab" "$pane" "$st" "$purpose"
done
echo; echo "== tasks =="
jq -r '.[]? | "\(.id)\t\(.state)\t\(.owner // "-")\t\(.title)"' "$h/tasks.json" 2>/dev/null | column -t -s $'\t'
echo; echo "== recent messages =="
tail -n 8 "$h/messages.log" 2>/dev/null
