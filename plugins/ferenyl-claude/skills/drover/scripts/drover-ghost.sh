#!/usr/bin/env bash
# drover-ghost.sh start|stop|watch <drover-id>
# Hidden oversized client (zellij sizes a tab to its smallest client, so it never caps the user's).
# Without an attached client zellij 0.45 does not apply a layout to new tabs, panes end up 1x1 and claude blocks on write.
# watch: keeps the corral tab (dashboard) at position 0 and the drover tab at 1, recreates a closed
# corral tab (never the drover), and cleans up when the session is gone.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
h="$HOME/.claude/drover/$2"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
sess() { jq -r .session "$h/registry.json"; }

stop() {
  if [[ -f $h/ghost.pids ]]; then
    while read -r p; do [[ $p == "$$" ]] || kill "$p" 2> /dev/null || true; done < "$h/ghost.pids"
  fi
  rm -f "$h/ghost.in" "$h/ghost.pids"
}

case $1 in
  start)
    s=$(sess)
    [[ -p $h/ghost.in ]] || mkfifo "$h/ghost.in"
    setsid sleep infinity > "$h/ghost.in" 2> /dev/null < /dev/null &
    echo $! > "$h/ghost.pids"
    setsid script -qfc "stty rows 300 cols 1000; zellij attach '$s'" /dev/null < "$h/ghost.in" > /dev/null 2>&1 &
    echo $! >> "$h/ghost.pids"
    for _ in $(seq 20); do
      if (($(timeout 10 zellij -s "$s" action list-clients 2> /dev/null | wc -l) > 1)); then
        setsid "$0" watch "$2" > /dev/null 2>&1 < /dev/null &
        echo $! >> "$h/ghost.pids"
        exit 0
      fi
      sleep 0.5
    done
    echo "no client attached to $s" >&2
    exit 1
    ;;
  watch)
    exec 9> "$h/ghost.lock"
    flock -n 9 || exit 0
    miss=0 dead=0
    while sleep 10; do
      IFS=$'\x1f' read -r s closing cid did < <(jq -r '[.session, (.closing_at // 0), (.corral_tab_id // "-"), (.drover.tab_id // "-")] | map(tostring) | join("\u001f")' "$h/registry.json")
      rc=0
      alive "$s" || rc=$?
      ((rc != 2)) || continue
      if ((rc == 1)); then
        ((++dead >= 2)) && break
        continue
      fi
      dead=0
      now=$(date +%s)
      ((closing + 60 < now)) || continue # a close is running
      tabs=$(timeout 10 zellij -s "$s" action list-tabs -j 2> /dev/null) || continue
      # Tabs are tracked by id: the corral tab sits at position 0, the drover tab at 1 (the user may move them).
      # one jq: corral tab id, corral tab present, extra corral tabs, drover tab missing, order wrong
      IFS=$'\t' read -r cid ok extra dgone reorder < <(jq -r --arg c "$cid" --arg d "$did" '
        if (type == "array" and length > 0) | not then empty else
        def num: try tonumber catch null;
        ($c | num) as $c0 | ($d | num) as $did
        | ($c0 // ([.[] | select(.name == "corral") | .tab_id] | min)) as $cid
        | any(.[]; .tab_id == $cid) as $ok
        | [($cid // "-"), $ok, ([.[] | select(.name == "corral" and .tab_id != $cid) | .tab_id] | join(" ") | if . == "" then "-" else . end),
           ($ok and $did != null and (any(.[]; .tab_id == $did) | not)),
           ($ok and (any(.[]; .tab_id == $cid and .position != 0) or ($did != null and any(.[]; .tab_id == $did and .position != 1))))]
        | map(tostring) | join("\t") end' <<< "$tabs" 2> /dev/null) || continue
      [[ -n ${ok:-} ]] || continue
      if [[ $ok == true ]]; then
        miss=0
        if [[ $extra != - ]]; then
          for t in $extra; do
            timeout 10 zellij -s "$s" action close-tab-by-id "$t" 2> /dev/null || true
          done
        fi
        if [[ $dgone == true ]]; then
          "$DIR/drover.sh" _drover_gone "$2" || true
        fi
        if [[ $reorder == true ]]; then
          "$DIR/drover.sh" _order "$2" || true
        fi
      else
        ((++miss >= 2)) || continue
        "$DIR/drover.sh" _recreate_corral "$2" || true # the dashboard only, never the drover
        miss=0
      fi
    done
    jfile "$h/registry.json" '.closed = true'
    stop
    ;;
  stop) stop ;;
esac
