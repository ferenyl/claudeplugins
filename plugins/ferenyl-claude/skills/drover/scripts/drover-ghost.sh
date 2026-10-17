#!/usr/bin/env bash
# drover-ghost.sh start|stop|watch <drover-id>
# Hidden oversized client (zellij sizes a tab to its smallest client, so it never caps the user's).
# Without an attached client zellij 0.45 does not apply a layout to new tabs, panes end up 1x1 and claude blocks on write.
# watch: recreates the "corral" tab if it is closed while agents exist,
# and cleans up when the session is gone.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
h="$HOME/.claude/drover/$2"
sess() { jq -r .session "$h/registry.json"; }
alive() { # no pipe from zellij into grep -q: an early exit would give zellij EPIPE and pipefail a false "dead"
  local out line
  out=$(zellij list-sessions -n 2> /dev/null) || true
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
    setsid sleep infinity > "$h/ghost.in" &
    echo $! > "$h/ghost.pids"
    setsid script -qfc "stty rows 300 cols 1000; zellij attach '$s'" /dev/null < "$h/ghost.in" > /dev/null 2>&1 &
    echo $! >> "$h/ghost.pids"
    for _ in $(seq 20); do
      if (($(zellij -s "$s" action list-clients 2> /dev/null | wc -l) > 1)); then
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
      if ! alive "$s"; then
        ((++dead >= 2)) && break
        continue
      fi
      dead=0
      (($(jq '.agents | length' "$h/registry.json") > 0)) || continue
      tabs=$(zellij -s "$s" action list-tabs -j 2> /dev/null) || continue
      jq -e 'type == "array" and length > 0' <<< "$tabs" > /dev/null 2>&1 || continue
      n=$(jq '[.[] | select(.name == "corral")] | length' <<< "$tabs")
      if ((n == 0)); then
        ((++miss >= 2)) || continue
        zellij -s "$s" action new-tab --name corral --no-focus -- watch -t -n2 "$DIR/drover-dashboard.sh $2" > /dev/null
        miss=0
      elif ((n > 1)); then
        for t in $(jq -r '[.[] | select(.name == "corral") | .tab_id] | sort | .[1:][]' <<< "$tabs"); do
          zellij -s "$s" action close-tab-by-id "$t" 2> /dev/null || true
        done
      fi
      ((n == 0)) || miss=0
    done
    jq '.closed = true' "$h/registry.json" > "$h/registry.json.tmp" && mv "$h/registry.json.tmp" "$h/registry.json"
    stop
    ;;
  stop) stop ;;
esac
