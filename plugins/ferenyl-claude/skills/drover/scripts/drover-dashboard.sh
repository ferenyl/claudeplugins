#!/usr/bin/env bash
# drover-dashboard.sh <drover-id>
h="$HOME/.claude/drover/$1"
s=$(jq -r .session "$h/registry.json" 2>/dev/null)
echo "== $s ==  zellij attach $s  (detach: Ctrl-o d)"
jq -r '"flow: " + (.flow | if . == null then "ask" else "\(.name) [\(.steps | join(" "))]\(if (.tracker | length) > 0 then " tracker=" + (.tracker | join(",")) else "" end)" end)' "$h/registry.json" 2>/dev/null
echo "== agents =="
# one jq over registry + status files; AGE = time since the last hook event, "gone" = pane no longer exists
shopt -s nullglob
c="$h/panes.cache" # zellij is only asked every 10s
if [[ ! -s $c ]] || (($(printf '%(%s)T') - $(stat -c %Y "$c") > 10)); then
  timeout 5 zellij -s "$s" action list-panes -j 2> /dev/null | jq -c '[.[] | "terminal_\(.id)"]' > "$c.tmp" 2> /dev/null
  if [[ -s $c.tmp ]]; then mv "$c.tmp" "$c"; else rm -f "$c.tmp"; fi
fi
panes=$(cat "$c" 2> /dev/null || true)
jq -rn --slurpfile r "$h/registry.json" --argjson live "${panes:-null}" \
  'reduce inputs as $x ({}; .[input_filename | sub(".*/"; "") | sub("\\.json$"; "")] = $x) as $st
  | def row($id; $model; $tab; $pane; $purpose):
      ($st[$id] // null) as $s
      | (if $s == null then "-" else "\($s.state) \($s.at)" end) as $state
      | (if $s == null then "-" elif ($live != null and $pane != "-" and ($live | index($pane) | not)) then "gone"
         else ((now - (try ($s.at | fromdate) catch now)) | floor | if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m" else "\(. / 3600 | floor)h" end) end) as $age
      | [$id, $model, $tab, $pane, $state, $age, $purpose] | join("\u001f");
    $r[0] as $reg
    | (if $reg.drover then row("drover"; $reg.drover.model; "drover"; "-"; "orchestrator") else empty end),
      ($reg.agents | to_entries[] | row(.key; .value.model // "-"; .value.tab_name // "-"; .value.pane_id; .value.purpose))' \
  /dev/null "$h"/status/*.json 2> /dev/null |
while IFS=$'\x1f' read -r id model tab pane st age purpose; do
  printf '%-16s %-8s %-12s %-12s %-28s %-5s %s\n' "$id" "$model" "$tab" "$pane" "$st" "$age" "$purpose"
done
echo; echo "== tasks =="
jq -r --arg all "${2:-}" '(.[]? | select($all == "--all" or .state != "done") | "\(.id)\t\(.state)\t\(.owner // "-")\t\(.title)"),
  (if $all != "--all" and ([.[]? | select(.state == "done")] | length) > 0 then "(\([.[] | select(.state == "done")] | length) done, status --all)\t\t\t" else empty end)' "$h/tasks.json" 2>/dev/null | column -t -s $'\t'
if [[ -f $h/stories.json ]]; then
  echo; echo "== stories =="
  "$(dirname "$0")/drover-story.sh" "$1" list 2>/dev/null
fi
echo; echo "== recent messages =="
tail -n 8 "$h/messages.log" 2>/dev/null
