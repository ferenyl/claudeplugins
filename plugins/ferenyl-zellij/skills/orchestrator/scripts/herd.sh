#!/usr/bin/env bash
# herd.sh <command> <herd-id> ... — see SKILL.md
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT="$HOME/.claude/herd"

die() { echo "$*" >&2; exit 1; }
reg() { echo "$ROOT/$HID/registry.json"; }
sess() { jq -r .session "$(reg)"; }
z() { zellij -s "$(sess)" action "$@"; }
jset() { local f; f=$(reg); jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
agent() { jq -r --arg a "$1" ".agents[\$a].$2 // empty" "$(reg)"; }
state() { jq -r '.state // "unknown"' "$ROOT/$HID/status/$1.json" 2>/dev/null || echo unknown; }
banner() { local s; s=$(sess); printf '\nSession: %s\nzellij attach %s\n' "$s" "$s"; }
alive() { zellij list-sessions -n 2>/dev/null | grep -E "^$1 " | grep -qv EXITED; }

type_in() { # pane text
  z paste -p "$1" "$2"
  z send-keys -p "$1" Enter
}

send() { # to from msg
  local to=$1 from=$2 msg=$3 h="$ROOT/$HID" line pane
  line="$(date -Is) [$from -> $to] $msg"
  if [[ $to == orchestrator ]]; then
    echo "$line" >> "$h/inbox/orchestrator.log"
  else
    pane=$(agent "$to" pane_id)
    [[ -n $pane ]] || die "unknown agent: $to"
    type_in "$pane" "[from $from] $msg"
  fi
  echo "$line" >> "$h/messages.log"
}

broadcast() { # from msg [except]
  local a
  for a in $(jq -r '.agents | keys[]' "$(reg)"); do
    [[ $a == "${3:-}" ]] || send "$a" "$1" "$2" || true
  done
}

wait_idle() {
  local s
  for _ in $(seq 60); do
    s=$(state "$1")
    [[ $s == idle ]] && return 0
    sleep 2
  done
  die "$1 is not idle (state: $s)"
}

tab_empty() { # tab_id
  ! z list-panes -j -t | jq -e --argjson t "$1" 'any(.[]; .tab_id==$t and .is_plugin==false)' > /dev/null
}

close_agent_pane() { # id
  local pane tab
  pane=$(agent "$1" pane_id) tab=$(agent "$1" tab_id)
  type_in "$pane" "/exit" || true
  sleep 2
  z close-pane -p "$pane" 2> /dev/null || true
  tab_empty "$tab" && z close-tab-by-id "$tab" 2> /dev/null || true
}

write_files() { # id purpose
  local id=$1 purpose=$2 h="$ROOT/$HID" others
  others=$(jq -r --arg a "$id" '.agents | to_entries[] | select(.key != $a) | "- \(.key): \(.value.purpose)"' "$(reg)")
  cat > "$h/agents/$id.prompt.md" <<EOF
You are agent $id in herd $HID. Purpose: $purpose
Only do what is within your purpose.

Other agents:
${others:-(none yet)}

You may and should talk directly to each other when needed:
$DIR/herd.sh send $HID <to-id|orchestrator> $id "<one-line message>"
Longer content: write a file in $h and send the path.

When a task is done: write $h/reports/$id.md
  task: <id> | status: done|blocked|failed | changed: <files> | summary: <1-3 lines> | open: <questions>
and send "done: <task-id>" to orchestrator.
EOF
  jq -n --arg c "$DIR/herd-status.sh" --arg f "$h/status/$id.json" '{hooks: {
    UserPromptSubmit: [{hooks: [{type: "command", command: "\($c) busy \($f)"}]}],
    Stop: [{hooks: [{type: "command", command: "\($c) idle \($f)"}]}]}}' > "$h/agents/$id.settings.json"
}

launch() { # id where cwd model -- claude-args...
  local id=$1 where=$2 cwd=$3 model=$4 h="$ROOT/$HID" tab pane target
  shift 5
  local cmd=(claude --model "$model" --settings "$h/agents/$id.settings.json"
    --append-system-prompt-file "$h/agents/$id.prompt.md" -n "$HID/$id" "$@")
  case $where in
    tab)
      tab=$(z new-tab --name "$id" --cwd "$cwd" --no-focus -- "${cmd[@]}")
      pane=$(z list-panes -j -t | jq -r --argjson t "$tab" '[.[] | select(.tab_id==$t and .is_plugin==false)][0].id | "terminal_\(.)"')
      ;;
    pane:*)
      target=${where#pane:}
      tab=$(agent "$target" tab_id)
      [[ -n $tab ]] || die "unknown agent: $target"
      pane=$(z new-pane --tab-id "$tab" --direction right --name "$id" --cwd "$cwd" --no-focus -- "${cmd[@]}")
      ;;
    *) die "placement must be tab or pane:<agent-id>" ;;
  esac
  echo "$tab $pane"
}

trusted() { jq -e --arg d "$1" '.projects[$d].hasTrustDialogAccepted == true' ~/.claude.json > /dev/null 2>&1; }

cmd=${1:-}; shift || true
case $cmd in
  new) # new <slug> <project-dir>
    slug=$1 proj=$(realpath "$2")
    HID=$(cut -c1-8 /proc/sys/kernel/random/uuid)
    S="claude-$slug" n=2
    while zellij list-sessions -s 2> /dev/null | grep -qx "$S"; do S="claude-$slug-$((n++))"; done
    h="$ROOT/$HID"
    mkdir -p "$h"/{agents,status,reports,inbox}
    jq -n --arg id "$HID" --arg s "$S" --arg p "$proj" --arg o "$PWD" \
      '{id: $id, session: $s, project: $p, orchestrator_cwd: $o, closed: false, agents: {}}' > "$h/registry.json"
    echo '[]' > "$h/tasks.json"
    (cd "$proj" && zellij attach --create-background "$S")
    "$DIR/herd-ghost.sh" start "$HID"
    z rename-tab-by-id 0 orchestrator
    type_in terminal_0 "watch -n2 '$DIR/herd-dashboard.sh $HID'"
    echo "HID=$HID"
    banner
    ;;
  spawn) # spawn <hid> <id> <model> <tab|pane:<agent>> <cwd> <purpose> <first task> [--trust]
    HID=$1 id=$2 model=$3 where=$4 cwd=$(realpath "$5") purpose=$6 task=$7 trust=${8:-}
    [[ -z $(agent "$id" pane_id) ]] || die "agent finns redan: $id"
    if ! trusted "$cwd" && [[ $trust != --trust ]]; then
      echo "UNTRUSTED $cwd — ask the user, then run again with --trust" >&2; exit 3
    fi
    write_files "$id" "$purpose"
    csid=$(cat /proc/sys/kernel/random/uuid)
    read -r tab pane < <(launch "$id" "$where" "$cwd" "$model" -- --session-id "$csid" "$task")
    jset --arg a "$id" --arg p "$purpose" --arg m "$model" --argjson t "$tab" --arg pn "$pane" \
      --arg c "$csid" --arg d "$cwd" --arg tn "$( [[ $where == tab ]] && echo "$id" || agent "${where#pane:}" tab_name)" \
      '.agents[$a] = {purpose: $p, model: $m, tab_id: $t, tab_name: $tn, pane_id: $pn, claude_session_id: $c, cwd: $d, worktree: null, created: (now | todate)}'
    if [[ $trust == --trust ]] && ! trusted "$cwd"; then
      sleep 4
      z send-keys -p "$pane" Down Enter
      echo "trust answered — verify: zellij -s $(sess) action dump-screen -p $pane"
    fi
    broadcast orchestrator "ny agent $id: $purpose" "$id"
    echo "$id $pane (tab $tab, $model)"
    banner
    ;;
  send) # send <hid> <to> <from> <message>
    HID=$1
    send "$2" "$3" "${*:4}"
    ;;
  model) # model <hid> <id> <model>
    HID=$1 id=$2 model=$3
    wait_idle "$id"
    type_in "$(agent "$id" pane_id)" "/model $model"
    jset --arg a "$id" --arg m "$model" '.agents[$a].model = $m'
    echo "$id -> $model"
    banner
    ;;
  move) # move <hid> <id> <tab|pane:<agent>>
    HID=$1 id=$2 where=$3
    wait_idle "$id"
    sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
    sid=${sid:-$(agent "$id" claude_session_id)}
    cwd=$(agent "$id" cwd) model=$(agent "$id" model)
    close_agent_pane "$id"
    read -r tab pane < <(launch "$id" "$where" "$cwd" "$model" -- --resume "$sid")
    tn=$([[ $where == tab ]] && echo "$id" || agent "${where#pane:}" tab_name)
    jset --arg a "$id" --argjson t "$tab" --arg pn "$pane" --arg c "$sid" --arg tn "$tn" \
      '.agents[$a] += {tab_id: $t, tab_name: $tn, pane_id: $pn, claude_session_id: $c}'
    echo "$id -> $pane (tab $tab)"
    banner
    ;;
  kill) # kill <hid> <id>
    HID=$1 id=$2
    close_agent_pane "$id"
    jset --arg a "$id" 'del(.agents[$a])'
    broadcast orchestrator "agent $id is closed"
    echo "closed: $id"
    banner
    ;;
  rename) # rename <hid> <slug>
    HID=$1 new="claude-${2#claude-}"
    [[ $new != "$(sess)" ]] || die "session is already named $new"
    ! zellij list-sessions -s 2> /dev/null | grep -qx "$new" || die "session name taken: $new"
    z rename-session "$new"
    jset --arg s "$new" '.session = $s'
    banner
    ;;
  status) # status <hid>
    HID=$1
    "$DIR/herd-dashboard.sh" "$HID"
    banner
    ;;
  close) # close <hid>
    HID=$1 s=$(sess)
    zellij kill-session "$s" 2> /dev/null || true
    zellij delete-session "$s" 2> /dev/null || true
    "$DIR/herd-ghost.sh" stop "$HID"
    jset '.closed = true | .agents = {}'
    echo "shut down: $s"
    ;;
  *) die "commands: new spawn send model move kill rename status close" ;;
esac
