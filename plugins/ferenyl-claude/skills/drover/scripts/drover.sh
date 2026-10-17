#!/usr/bin/env bash
# drover.sh <command> <drover-id> ... — see SKILL.md
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT="$HOME/.claude/drover"
# Claude-session env that must not leak into the zellij server or agents (breaks transcripts, --resume, titles)
CLEAN_ENV=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH
  -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_ENV_FILE -u DROVER_SESSION_ID -u DROVER_TRANSCRIPT)

die() { echo "$*" >&2; exit 1; }
reg() { echo "$ROOT/$HID/registry.json"; }
sess() { jq -r .session "$(reg)"; }
z() { zellij -s "$(sess)" action "$@"; }
jset() { local f; f=$(reg); jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
agent() { jq -r --arg a "$1" ".agents[\$a].$2 // empty" "$(reg)"; }
state() { jq -r '.state // "unknown"' "$ROOT/$HID/status/$1.json" 2>/dev/null || echo unknown; }
banner() {
  local s
  s=$(sess)
  printf '\nSession: %s\nzellij attach %s\n' "$s" "$s"
}
drover_title() { # title the drover session (ids recorded by the SessionStart hook)
  local n i t
  n="drover-$(jq -r .slug "$(reg)")-$HID"
  i=${DROVER_SESSION_ID:-} t=${DROVER_TRANSCRIPT:-}
  if [[ -n $i && -n $t ]]; then
    jset --arg i "$i" --arg t "$t" '.drover_session_id = $i | .drover_transcript = $t'
  else
    i=$(jq -r '.drover_session_id // empty' "$(reg)") t=$(jq -r '.drover_transcript // empty' "$(reg)")
  fi
  bash "$DIR/drover-title.sh" "$t" "$i" "$n" || echo "drover session unknown: run /rename $n" >&2
}
slugify() { local x=${1#corral-}; x=${x%-"$HID"}; echo "$x"; }
alive() { # no pipe from zellij into grep -q: an early exit would give zellij EPIPE and pipefail a false "dead"
  local out line
  out=$(zellij list-sessions -n 2> /dev/null) || true
  line=$(grep -E "^$1 " <<< "$out" || true)
  [[ -n $line && $line != *EXITED* ]]
}

type_in() { # pane text [verify=1]: paste, settle, Enter, then check the text reached the pane; retry
  local pane=$1 text=$2 verify=${3:-1} needle screen _
  needle=${text:0:30}
  for _ in 1 2 3; do
    z paste -p "$pane" "$text" || return 1
    sleep 0.5
    z send-keys -p "$pane" Enter || return 1
    [[ $verify == 1 ]] || return 0
    sleep 1
    screen=$(z dump-screen -p "$pane" 2> /dev/null) || screen=
    ! grep -qF -- "$needle" <<< "$screen" || return 0
  done
  return 1
}

send() { # to from msg
  local to=$1 from=$2 msg=$3 h="$ROOT/$HID" line pane
  line="[$from -> $to] $msg"
  if [[ $to == drover ]]; then
    echo "$line" >> "$h/inbox/drover.log"
  else
    pane=$(agent "$to" pane_id)
    [[ -n $pane ]] || die "unknown agent: $to"
    if [[ $(state "$to") == blocked ]]; then # Enter would answer its dialog
      mkdir -p "$h/queue"
      printf '%s\t%s\n' "$from" "$msg" >> "$h/queue/$to.txt"
      echo "[drover-sh -> drover] queued for $to (blocked, needs input): $msg. After it is unblocked: drover.sh flush $HID $to" >> "$h/inbox/drover.log"
      echo "$(date -Is) $line (queued)" >> "$h/messages.log"
      echo "queued for $to (blocked)" >&2
      return 0
    fi
    type_in "$pane" "[from $from] $msg" || die "not delivered to $to"
  fi
  echo "$(date -Is) $line" >> "$h/messages.log"
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
  type_in "$pane" "/exit" 0 || true
  sleep 2
  z close-pane -p "$pane" 2> /dev/null || true
  tab_empty "$tab" && z close-tab-by-id "$tab" 2> /dev/null || true
}

write_files() { # id purpose
  local id=$1 purpose=$2 h="$ROOT/$HID"
  cat > "$h/agents/$id.prompt.md" <<EOF
You are agent $id in drover $HID. Purpose: $purpose
Only do what is within your purpose.

Agents (live list, read only if you need to message someone): $h/registry.json

You may and should talk directly to each other when needed:
$DIR/drover.sh send $HID <to-id|drover> $id "<one-line message>"
Longer content: write a file in $h and send the path.

When a task is done: write $h/reports/$id.md
  task: <id> | status: done|blocked|failed | changed: <files> | summary: <1-3 lines> | open: <questions>
and send "done: <task-id>" to drover.
EOF
  jq -n --arg c "$DIR/drover-status.sh" --arg f "$h/status/$id.json" --arg d "$DIR" '{permissions: {allow: ["Bash(\($d)/drover.sh send *)"]}, hooks: {
    UserPromptSubmit: [{hooks: [{type: "command", command: "\($c) busy \($f)"}]}],
    Stop: [{hooks: [{type: "command", command: "\($c) idle \($f)"}]}],
    Notification: [{matcher: "permission_prompt|elicitation_dialog", hooks: [{type: "command", command: "\($c) blocked \($f)"}]}],
    PostToolUse: [{hooks: [{type: "command", command: "\($c) unblock \($f)"}]}]}}' > "$h/agents/$id.settings.json"
}

launch() { # id where cwd model -- claude-args...
  local id=$1 where=$2 cwd=$3 model=$4 h="$ROOT/$HID" tab pane target
  shift 5
  local cmd=("${CLEAN_ENV[@]}" DROVER_AGENT=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude --model "$model" --settings "$h/agents/$id.settings.json"
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
    slug=$(slugify "$slug") S="corral-$slug-$HID"
    h="$ROOT/$HID"
    mkdir -p "$h"/{agents,status,reports,inbox}
    jq -n --arg id "$HID" --arg s "$S" --arg sl "$slug" --arg p "$proj" --arg o "$PWD" \
      '{id: $id, session: $s, project: $p, slug: $sl, drover_cwd: $o, closed: false, agents: {}}' > "$h/registry.json"
    echo '[]' > "$h/tasks.json"
    dsid=${DROVER_SESSION_ID:-} dtp=${DROVER_TRANSCRIPT:-}
    if [[ -z $dsid ]]; then
      f="$ROOT/sessions/$(printf %s "$PWD" | md5sum | cut -c1-12).json"
      dsid=$(jq -r '.session_id // empty' "$f" 2> /dev/null) dtp=$(jq -r '.transcript_path // empty' "$f" 2> /dev/null)
    fi
    jset --arg i "$dsid" --arg t "$dtp" '.drover_session_id = $i | .drover_transcript = $t'
    (cd "$proj" && "${CLEAN_ENV[@]}" zellij attach --create-background "$S")
    "$DIR/drover-ghost.sh" start "$HID"
    z rename-tab-by-id 0 corral
    z new-pane --in-place --pane-id terminal_0 --close-replaced-pane --name corral -- watch -t -n2 "$DIR/drover-dashboard.sh $HID" > /dev/null
    echo "HID=$HID"
    drover_title
    banner
    ;;
  spawn) # spawn <hid> <id> <model> <tab|pane:<agent>> <cwd> <purpose> <first task> [--trust]
    HID=$1 id=$2 model=$3 where=$4 cwd=$(realpath "$5") purpose=$6 task=$7 trust=${8:-}
    [[ -z $(agent "$id" pane_id) ]] || die "agent exists: $id"
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
    type_in "$(agent "$id" pane_id)" "/model $model" || die "/model not delivered to $id"
    sleep 2
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
    write_files "$id" "$(agent "$id" purpose)"
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
    echo "closed: $id"
    banner
    ;;
  rename) # rename <hid> <slug>
    HID=$1 slug=$(slugify "$2")
    new="corral-$slug-$HID"
    [[ $new != "$(sess)" ]] || die "session is already named $new"
    ! zellij list-sessions -s 2> /dev/null | grep -qx "$new" || die "session name taken: $new"
    z rename-session "$new"
    jset --arg s "$new" --arg sl "$slug" '.session = $s | .slug = $sl'
    drover_title
    banner
    ;;
  flush) # flush <hid> <id> — deliver messages queued while the agent was blocked
    HID=$1 id=$2 q="$ROOT/$HID/queue/$2.txt"
    [[ -s $q ]] || die "nothing queued for $id"
    [[ $(state "$id") != blocked ]] || die "$id is still blocked"
    while IFS=$'\t' read -r f m; do
      type_in "$(agent "$id" pane_id)" "[from $f] $m" || die "not delivered to $id"
    done < "$q"
    rm -f "$q"
    echo "flushed: $id"
    ;;
  read) # read <hid> <id> [lines]
    HID=$1 id=$2
    pane=$(agent "$id" pane_id)
    [[ -n $pane ]] || die "unknown agent: $id"
    z dump-screen -p "$pane" | tail -n "${3:-40}"
    ;;
  revive) # revive <hid> — recreate session if dead and relaunch all agents with --resume
    HID=$1 s=$(sess) proj=$(jq -r .project "$(reg)")
    if ! alive "$s"; then
      zellij delete-session "$s" 2> /dev/null || true
      (cd "$proj" && "${CLEAN_ENV[@]}" zellij attach --create-background "$s")
      "$DIR/drover-ghost.sh" start "$HID"
      z rename-tab-by-id 0 corral
      z new-pane --in-place --pane-id terminal_0 --close-replaced-pane --name corral -- watch -t -n2 "$DIR/drover-dashboard.sh $HID" > /dev/null
    elif ! kill -0 "$(sed -n 2p "$ROOT/$HID/ghost.pids" 2> /dev/null)" 2> /dev/null; then
      "$DIR/drover-ghost.sh" stop "$HID"
      "$DIR/drover-ghost.sh" start "$HID"
    fi
    jset '.closed = false'
    for id in $(jq -r '.agents | keys[]' "$(reg)"); do
      [[ -z $(z list-panes -j -t | jq -r --arg p "$(agent "$id" pane_id)" '.[] | select("terminal_\(.id)" == $p) | .id') ]] || continue
      sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
      sid=${sid:-$(agent "$id" claude_session_id)}
      write_files "$id" "$(agent "$id" purpose)"
      read -r tab pane < <(launch "$id" tab "$(agent "$id" cwd)" "$(agent "$id" model)" -- --resume "$sid")
      jset --arg a "$id" --argjson t "$tab" --arg pn "$pane" --arg c "$sid" \
        '.agents[$a] += {tab_id: $t, tab_name: $a, pane_id: $pn, claude_session_id: $c}'
      echo "revived: $id -> $pane"
    done
    banner
    ;;
  status) # status <hid>
    HID=$1
    "$DIR/drover-dashboard.sh" "$HID"
    banner
    ;;
  close) # close <hid>
    HID=$1 s=$(sess)
    zellij kill-session "$s" 2> /dev/null || true
    zellij delete-session "$s" 2> /dev/null || true
    "$DIR/drover-ghost.sh" stop "$HID"
    jset '.closed = true | .agents = {}'
    echo "shut down: $s"
    ;;
  *) die "commands: new spawn send model move kill rename flush read revive status close" ;;
esac
