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

# Git/PR flows: a flow is a set of pre-approved steps (see SKILL.md); unset = ask for every write
FLOW_STEPS="commit merge-local push pr-link pr pr-draft review-post review-approve review-fix checks merge-pr merge-ask tracker-assign tracker-status tracker-comment tracker-link"
flow_builtin() { # name: its steps (none = empty); 1 if not a built-in
  case $1 in
    none) ;;
    commit) echo commit ;;
    local-merge) echo commit merge-local ;;
    push) echo commit push ;;
    manual-pr) echo commit push pr-link ;;
    pr) echo commit push pr ;;
    pr-draft) echo commit push pr-draft ;;
    pr-review) echo commit push pr review-post ;;
    pr-approve) echo commit push pr review-post review-approve ;;
    pr-merge) echo commit push pr review-post review-approve checks merge-ask ;;
    pr-fix) echo commit push pr review-post review-fix ;;
    full) echo commit push pr review-post review-fix checks merge-pr ;;
    *) return 1 ;;
  esac
}
flow_resolve() { # name: flow json {name, steps, file?}; built-in names cannot be shadowed, then <project>/.drover/flows, then ~/.claude/drover/flows
  local n=$1 s f x p
  if s=$(flow_builtin "$n"); then
    jq -nc --arg n "$n" --arg s "$s" '{name: $n, steps: ($s | split(" ") | map(select(. != "")))}'
    return
  fi
  [[ $n =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad flow name: $n"
  p=$(jq -r .project "$HOME/.claude/drover/$HID/registry.json")
  for f in "$p/.drover/flows/$n.md" "$HOME/.claude/drover/flows/$n.md"; do
    [[ -f $f ]] || continue
    s=$(sed -n '/^steps:/{s/^steps:[[:space:]]*//p;q}' "$f")
    for x in $s; do [[ " $FLOW_STEPS " == *" $x "* ]] || die "unknown step '$x' in $f; valid: $FLOW_STEPS"; done
    jq -nc --arg n "$n" --arg s "$s" --arg f "$f" '{name: $n, steps: ($s | split(" ") | map(select(. != ""))), file: $f}'
    return
  done
  die "unknown flow: $n (built-in: none commit local-merge push manual-pr pr pr-draft pr-review pr-approve pr-merge pr-fix full; custom: <project>/.drover/flows/$n.md or ~/.claude/drover/flows/$n.md with a 'steps:' line)"
}
flow_story() { # sid: the story's own flow json, empty if none
  jq -c --arg i "$1" '.[] | select(.id == $i) | .flow // empty' "$HOME/.claude/drover/$HID/stories.json" 2> /dev/null || true
}
flow_json() { # [sid]: effective flow json: the story's, else the corral's, else empty (= ask)
  {
    [[ -z ${1:-} ]] || flow_story "$1"
    jq -c '.flow // empty' "$HOME/.claude/drover/$HID/registry.json"
  } | awk 'NR == 1'
}
flow_steps() { # [sid]: steps the effective flow pre-approves, one per line
  flow_json "${1:-}" | jq -r '(.steps[]?, (.tracker[]? | "tracker-" + .))'
}
flow_has() { # step [sid]
  flow_steps "${2:-}" | grep -xF -- "$1" > /dev/null
}
flow_line() { # [sid]: name [steps] tracker=…
  local f; f=$(flow_json "${1:-}")
  if [[ -z $f ]]; then echo ask; else
    jq -r '"\(.name) [\(.steps | join(" "))]\(if (.tracker | length) > 0 then " tracker=\(.tracker | join(","))" else "" end)"' <<< "$f"
  fi
}
# shellcheck disable=SC2016
flow_save() { # flow-json|null [sid]: store as the corral's flow, or the story's
  local d="$HOME/.claude/drover/$HID"
  if [[ -n ${2:-} ]]; then
    jfile "$d/stories.json" --arg i "$2" --argjson f "$1" 'map(if .id == $i then .flow = $f else . end)'
  else
    jfile "$d/registry.json" --argjson f "$1" '.flow = $f'
  fi
}
flow_gate() { # "step…" sid "action": ok if the flow lists one of the steps or YES=1 (--yes); else exit 6
  local s
  [[ ${YES:-0} != 1 ]] || return 0
  for s in $1; do ! flow_has "$s" "$2" || return 0; done
  echo "not in flow $(flow_line "$2" | cut -d' ' -f1): ask the user \"$3?\", rerun with --yes after a yes" >&2
  exit 6
}
web_url() { # git remote url -> https web url
  sed -E 's#\.git$##; s#^(ssh://)?git@ssh\.dev\.azure\.com[:/]v3/([^/]+)/([^/]+)/(.+)$#https://dev.azure.com/\2/\3/_git/\4#; s#^(ssh://)?git@([^:/]+)[:/]#https://\2/#; s#^https://[^@/]+@#https://#' <<< "$1"
}
compare_url() { # remote base branch: the host's create-PR page
  local u e
  u=$(web_url "$1") e=$(jq -rn --arg b "$3" '$b | @uri')
  case $u in
    *github.com*) echo "$u/compare/$2...$3?expand=1" ;;
    *dev.azure.com* | *visualstudio.com*) echo "$u/pullrequestcreate?sourceRef=$e&targetRef=$(jq -rn --arg b "$2" '$b | @uri')" ;;
    *gitlab*) echo "$u/-/merge_requests/new?merge_request[source_branch]=$e&merge_request[target_branch]=$2" ;;
    *) die "PR host not supported for remote: $1" ;;
  esac
}
