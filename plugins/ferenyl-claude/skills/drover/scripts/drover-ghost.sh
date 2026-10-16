#!/usr/bin/env bash
# drover-ghost.sh start|stop|watch <drover-id>
# Hidden fixed-size client. Without an attached client zellij 0.45 doesn't apply a layout
# to new tabs, panes end up 1x1 and claude blocks on write.
# watch: recreates the "corral" tab if it is closed while agents exist,
# and cleans up when the session is gone.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
h="$HOME/.claude/drover/$2"
sess() { jq -r .session "$h/registry.json"; }
alive() { zellij list-sessions -n 2> /dev/null | grep -E "^$1 " | grep -qv EXITED; }

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
    setsid script -qfc "stty rows 50 cols 160; zellij attach '$s'" /dev/null < "$h/ghost.in" > /dev/null 2>&1 &
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
    while sleep 5; do
      s=$(sess)
      alive "$s" || break
      zellij -s "$s" action query-tab-names 2> /dev/null | grep -qx corral && continue
      (($(jq '.agents | length' "$h/registry.json") > 0)) || continue
      zellij -s "$s" action new-tab --name corral --no-focus -- watch -n2 "$DIR/drover-dashboard.sh $2" > /dev/null
    done
    jq '.closed = true | .agents = {}' "$h/registry.json" > "$h/registry.json.tmp" && mv "$h/registry.json.tmp" "$h/registry.json"
    stop
    ;;
  stop) stop ;;
esac
