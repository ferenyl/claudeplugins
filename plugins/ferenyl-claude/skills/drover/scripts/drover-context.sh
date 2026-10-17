#!/usr/bin/env bash
# SessionStart hook: record this session, print active drover sessions for the current directory, reapply the drover title.
set -uo pipefail
[[ -n ${DROVER_AGENT:-} ]] && exit 0
in=$(cat)
cwd=$(jq -r '.cwd // empty' <<< "$in" 2>/dev/null)
cwd=${cwd:-$PWD}
sid=$(jq -r '.session_id // empty' <<< "$in" 2>/dev/null)
tp=$(jq -r '.transcript_path // empty' <<< "$in" 2>/dev/null)
src=$(jq -r '.source // empty' <<< "$in" 2>/dev/null)
D="$HOME/.claude/drover"
if [[ -n $sid && -n $tp ]]; then
  mkdir -p "$D/sessions"
  jq -n --arg i "$sid" --arg t "$tp" '{session_id: $i, transcript_path: $t}' > "$D/sessions/$(printf %s "$cwd" | md5sum | cut -c1-12).json"
  [[ -n ${CLAUDE_ENV_FILE:-} ]] && printf 'export DROVER_SESSION_ID=%q DROVER_TRANSCRIPT=%q\n' "$sid" "$tp" >> "$CLAUDE_ENV_FILE"
fi
for r in "$D"/*/registry.json; do
  [[ -f $r ]] || continue
  if jq -e --arg c "$cwd" '.drover_cwd == $c and .closed and (.agents | length > 0)' "$r" >/dev/null 2>&1; then
    jq -r '"Drover \(.id): corral session dead, \(.agents | length) agents saved — run drover.sh revive \(.id)."' "$r"
    continue
  fi
  jq -e --arg c "$cwd" '.drover_cwd == $c and (.closed | not)' "$r" >/dev/null 2>&1 || continue
  h=$(dirname "$r")
  old=$(jq -r '.drover_session_id // empty' "$r")
  if [[ -n $sid && -n $tp && ( $src == clear || $src == compact || -z $old || $old == "$sid" ) ]]; then
    jq --arg i "$sid" --arg t "$tp" '.drover_session_id = $i | .drover_transcript = $t' "$r" > "$r.tmp" && mv "$r.tmp" "$r"
    [[ $old == "$sid" ]] || bash "$(dirname "$0")/drover-title.sh" "$tp" "$sid" "drover-$(jq -r .slug "$r")-$(jq -r .id "$r")"
  fi
  jq -r '"Active drover \(.id), session \(.session) — you are the drover, use /ferenyl-claude:drover."' "$r"
  jq -r '.agents | to_entries[] | "\(.key)\t\(.value.model)\t\(.value.pane_id)\t\(.value.purpose)"' "$r" |
  while IFS=$'\t' read -r id m p purpose; do
    st=$(jq -r .state "$h/status/$id.json" 2>/dev/null || echo unknown)
    echo "- $id [$m, $p, $st]: $purpose"
  done
done
exit 0
