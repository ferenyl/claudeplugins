#!/usr/bin/env bash
# SessionStart-hook: skriv ut aktiva herds för aktuell katalog.
set -uo pipefail
cwd=$(jq -r '.cwd // empty' 2>/dev/null)
cwd=${cwd:-$PWD}
for r in "$HOME"/.claude/herd/*/registry.json; do
  [[ -f $r ]] || continue
  jq -e --arg c "$cwd" '.orchestrator_cwd == $c and (.closed | not)' "$r" >/dev/null 2>&1 || continue
  h=$(dirname "$r")
  echo "Aktiv zellij-orchestrator herd (använd skill zellij-orchestrator). State: $h"
  cat "$r"
  for f in "$h"/status/*.json; do [[ -f $f ]] && echo "$(basename "$f" .json): $(cat "$f")"; done
  echo
done
exit 0
