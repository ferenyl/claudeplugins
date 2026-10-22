# shellcheck shell=bash
# Shared by drover.sh and drover-story.sh (sourced).
die() { echo "$*" >&2; exit 1; }
notify() { # notify-send args; DROVER_NOTIFY=0 turns notifications off
  [[ ${DROVER_NOTIFY:-1} != 0 ]] && command -v notify-send > /dev/null && notify-send "$@" || true
}
jfile() { # file jq-args...: several writers (close, watcher, hooks): serialize on a lock, write via a private temp file
  local f=$1; shift
  (
    flock 8
    local t; t=$(mktemp "$f.XXXXXX")
    jq "$@" "$f" > "$t" || { rm -f "$t"; exit 1; }
    if cmp -s "$t" "$f"; then rm -f "$t"; else mv "$t" "$f"; fi # unchanged: keep mtime, watchers see no change
  ) 8> "$f.lock"
}
alive() { # 0 alive, 1 dead, 2 unknown (timeout). no pipe from zellij into grep -q: an early exit would give zellij EPIPE and pipefail a false "dead"
  local out line rc=0
  out=$(timeout 10 zellij list-sessions -n 2> /dev/null) || rc=$?
  ((rc != 124)) || return 2 # timed out: unknown, not dead
  line=$(grep -E "^$1 " <<< "$out" || true)
  [[ -n $line && $line != *EXITED* ]]
}
