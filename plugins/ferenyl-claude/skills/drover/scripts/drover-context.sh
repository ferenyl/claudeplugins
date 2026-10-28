#!/usr/bin/env bash
# SessionStart hook: record this session, print active drover sessions for the current directory, reapply the drover title.
# shellcheck disable=SC2154
set -uo pipefail
[[ -n ${DROVER_AGENT:-} ]] && exit 0
in=$(cat)
cwd='' sid='' tp='' src=''
eval "$(jq -r '@sh "cwd=\(.cwd // "") sid=\(.session_id // "") tp=\(.transcript_path // "") src=\(.source // "")"' <<< "$in" 2>/dev/null)"
cwd=${cwd:-$PWD}
D="$HOME/.claude/drover"
if [[ -n $sid && -n $tp ]]; then
  mkdir -p "$D/sessions"
  jq -n --arg i "$sid" --arg t "$tp" '{session_id: $i, transcript_path: $t}' > "$D/sessions/$(printf %s "$cwd" | md5sum | cut -c1-12).json"
  [[ -n ${CLAUDE_ENV_FILE:-} ]] && printf 'export DROVER_SESSION_ID=%q DROVER_TRANSCRIPT=%q\n' "$sid" "$tp" >> "$CLAUDE_ENV_FILE"
fi
. "$(dirname "$0")/lib.sh"
regset() { jfile "$@"; }
agents() { # registry
  local h; h=$(dirname "$1")
  jq -r '.agents | to_entries[] | "\(.key)\t\(.value.model)\t\(.value.pane_id)\t\(.value.purpose)"' "$1" |
  while IFS=$'\t' read -r id m p purpose; do
    st=$(jq -r .state "$h/status/$id.json" 2>/dev/null || echo unknown)
    echo "- $id [$m, $p, $st]: $purpose"
  done
}
if [[ -n ${DROVER_HID:-} ]]; then # this pane is the drover of one corral: look at that registry only
  r="$D/$DROVER_HID/registry.json"
  [[ -f $r ]] || exit 0
  old=$(jq -r '.drover.session_id // empty' "$r")
  if [[ -n $sid && -n $tp && ( $src == clear || $src == compact || $old == "$sid" ) ]]; then
    # shellcheck disable=SC2016
    regset "$r" --arg i "$sid" --arg t "$tp" '.drover.session_id = $i | .drover.transcript = $t'
    [[ $src != clear && $src != compact ]] || bash "$(dirname "$0")/drover-title.sh" "$tp" "$sid" "drover-$(jq -r .slug "$r")-$(jq -r .id "$r")"
  elif [[ $src == resume && -n $old && $old != "$sid" ]]; then
    echo "This pane is drover $DROVER_HID; resume its own session with /resume $old"
  fi
  jq -r '"Active drover \(.id), session \(.session) — you are the drover, use /ferenyl-claude:drover. Run drover.sh catchup \(.id), then re-arm the inbox Monitor with the Monitor tool, never Bash run_in_background (a /clear ends it, /compact does not): drover.sh inbox \(.id), timeout_ms 1800000."' "$r"
  agents "$r"
  [[ ! -f $D/$DROVER_HID/stories.json ]] || echo "Story mode: read $(cd "$(dirname "$0")/.." && pwd)/story.md; stories: drover.sh story $DROVER_HID list"
  exit 0
fi
for r in "$D"/*/registry.json; do
  [[ -f $r ]] || continue
  kind=$(jq -r --arg c "$cwd" 'if .drover_cwd != $c then "skip"
    elif .closed and (.shutdown | not) and ((.agents | length > 0) or .drover) then "dead"
    elif .drover.mode == "corral" and (.closed | not) then "inside"
    elif .closed | not then "ok" else "skip" end' "$r" 2>/dev/null)
  [[ $kind == skip || -z $kind ]] && continue
  if [[ $kind == dead ]]; then
    jq -r '"Drover \(.id): corral session dead, \(.agents | length) agents saved — run drover.sh revive \(.id)."' "$r"
    continue
  fi
  if [[ $kind == inside ]]; then # another session must not become a second drover
    jq -r '"Drover \(.id) runs inside \(.session) — attach: zellij attach \(.session)"' "$r"
    continue
  fi
  h=$(dirname "$r")
  old=$(jq -r '.drover_session_id // empty' "$r")
  if [[ -n $sid && -n $tp && ( $src == clear || $src == compact || -z $old || $old == "$sid" ) ]]; then
    # shellcheck disable=SC2016
    regset "$r" --arg i "$sid" --arg t "$tp" '.drover_session_id = $i | .drover_transcript = $t'
    [[ $old == "$sid" ]] || bash "$(dirname "$0")/drover-title.sh" "$tp" "$sid" "drover-$(jq -r .slug "$r")-$(jq -r .id "$r")"
  fi
  jq -r '"Active drover \(.id), session \(.session) — you are the drover, use /ferenyl-claude:drover."' "$r"
  agents "$r"
done
exit 0
