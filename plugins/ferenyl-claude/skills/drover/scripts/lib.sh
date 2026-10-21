# shellcheck shell=bash
# Shared by drover.sh and drover-story.sh (sourced).
die() { echo "$*" >&2; exit 1; }
jfile() { # file jq-args...: several writers (close, watcher, hooks): serialize on a lock, write via a private temp file
  local f=$1; shift
  (
    flock 8
    local t; t=$(mktemp "$f.XXXXXX")
    jq "$@" "$f" > "$t" || { rm -f "$t"; exit 1; }
    if cmp -s "$t" "$f"; then rm -f "$t"; else mv "$t" "$f"; fi # unchanged: keep mtime, watchers see no change
  ) 8> "$f.lock"
}
