#!/usr/bin/env bash
# drover-ghost.sh start|stop|watch <drover-id>
# Hidden oversized client (zellij sizes a tab to its smallest client, so it never caps the user's).
# Without an attached client zellij 0.45 does not apply a layout to new tabs, panes end up 1x1 and claude blocks on write.
# watch: keeps the corral tab (dashboard) at position 0 and the drover tab at 1, recreates a closed
# corral tab (never the drover), and cleans up when the session is gone.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
h="$HOME/.claude/drover/$2"
sess() { jq -r .session "$h/registry.json"; }
alive() { # 0 alive, 1 dead, 2 unknown (timeout). no pipe from zellij into grep -q: an early exit would give zellij EPIPE and pipefail a false "dead"
  local out line rc=0
  out=$(timeout 10 zellij list-sessions -n 2> /dev/null) || rc=$?
  ((rc != 124)) || return 2 # timed out: unknown, not dead
  line=$(grep -E "^$1 " <<< "$out" || true)
  [[ -n $line && $line != *EXITED* ]]
}

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
    while sleep 5; do
      s=$(sess)
      rc=0
      alive "$s" || rc=$?
      ((rc != 2)) || continue
      if ((rc == 1)); then
        ((++dead >= 2)) && break
        continue
      fi
      dead=0
      now=$(date +%s)
      (($(jq '.closing_at // 0' "$h/registry.json") + 60 < now)) || continue # a close is running
      tabs=$(timeout 10 zellij -s "$s" action list-tabs -j 2> /dev/null) || continue
      jq -e 'type == "array" and length > 0' <<< "$tabs" > /dev/null 2>&1 || continue
      # Tabs are tracked by id: the corral tab sits at position 0, the drover tab at 1 (the user may move them).
      cid=$(jq -r '.corral_tab_id // empty' "$h/registry.json")
      cid=${cid:-$(jq -r '[.[] | select(.name == "corral") | .tab_id] | min // empty' <<< "$tabs")}
      did=$(jq -r '.drover.tab_id // empty' "$h/registry.json")
      if jq -e --argjson c "${cid:--1}" 'any(.[]; .tab_id == $c)' <<< "$tabs" > /dev/null; then
        miss=0
        for t in $(jq -r --argjson c "$cid" '.[] | select(.name == "corral" and .tab_id != $c) | .tab_id' <<< "$tabs"); do
          timeout 10 zellij -s "$s" action close-tab-by-id "$t" 2> /dev/null || true
        done
        if [[ -n $did ]]; then
          if ! jq -e --argjson d "$did" 'any(.[]; .tab_id == $d)' <<< "$tabs" > /dev/null; then
            "$DIR/drover.sh" _drover_gone "$2" || true
          fi
        fi
        if jq -e --argjson c "$cid" --argjson d "${did:--1}" '
          (.[] | select(.tab_id == $c) | .position != 0) or any(.[]; .tab_id == $d and .position != 1)' <<< "$tabs" > /dev/null; then
          "$DIR/drover.sh" _order "$2" || true
        fi
      else
        ((++miss >= 2)) || continue
        "$DIR/drover.sh" _recreate_corral "$2" || true # the dashboard only, never the drover
        miss=0
      fi
    done
    (
      flock 8
      jq '.closed = true' "$h/registry.json" > "$h/registry.json.w" && mv "$h/registry.json.w" "$h/registry.json"
    ) 8> "$h/registry.json.lock"
    stop
    ;;
  stop) stop ;;
esac
