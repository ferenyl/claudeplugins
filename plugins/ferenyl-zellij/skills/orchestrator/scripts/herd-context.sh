#!/usr/bin/env bash
# SessionStart hook: print active herds for the current directory.
set -uo pipefail
cwd=$(jq -r '.cwd // empty' 2>/dev/null)
cwd=${cwd:-$PWD}
for r in "$HOME"/.claude/herd/*/registry.json; do
  [[ -f $r ]] || continue
  jq -e --arg c "$cwd" '.orchestrator_cwd == $c and (.closed | not)' "$r" >/dev/null 2>&1 || continue
  h=$(dirname "$r")
  jq -r '"Active herd \(.id), session \(.session) — you are the orchestrator, use /ferenyl-zellij:orchestrator."' "$r"
  jq -r '.agents | to_entries[] | "\(.key)\t\(.value.model)\t\(.value.pane_id)\t\(.value.purpose)"' "$r" |
  while IFS=$'\t' read -r id m p purpose; do
    st=$(jq -r .state "$h/status/$id.json" 2>/dev/null || echo unknown)
    echo "- $id [$m, $p, $st]: $purpose"
  done
done
exit 0
