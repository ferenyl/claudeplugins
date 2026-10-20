#!/usr/bin/env bash
# drover.sh <command> <drover-id> ... — see SKILL.md
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT="$HOME/.claude/drover"
# Claude-session env that must not leak into the zellij server or agents (breaks transcripts, --resume, titles)
CLEAN_ENV=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH
  -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_ENV_FILE
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_EFFORT -u DROVER_SESSION_ID -u DROVER_TRANSCRIPT -u DROVER_HID)
# The zellij server must not inherit a pane's ZELLIJ*: attach --create-background from inside a pane would add a tab to that session.
# Agent panes keep theirs (set by zellij itself), the status hook needs them.
SERVER_ENV=("${CLEAN_ENV[@]}" -u DROVER_AGENT -u ZELLIJ -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID)

die() { echo "$*" >&2; exit 1; }
reg() { echo "$ROOT/$HID/registry.json"; }
sess() { jq -r .session "$(reg)"; }
z() { timeout 10 zellij -s "$(sess)" action "$@"; }
jset() { jfile "$(reg)" "$@"; }
tset() { jfile "$ROOT/$HID/tasks.json" "$@"; }
jfile() { # file jq-args...: several writers (close, watcher, hooks): serialize on a lock, write via a private temp file
  local f=$1; shift
  (
    flock 8
    local t; t=$(mktemp "$f.XXXXXX")
    # shellcheck disable=SC2015
    jq "$@" "$f" > "$t" && mv "$t" "$f" || { rm -f "$t"; exit 1; }
  ) 8> "$f.lock"
}
inside() { [[ ${DROVER_HID:-} == "$HID" ]]; }
guard_outside() { # the drover lives in its corral; other sessions must not drive it
  [[ $FORCE == 1 || $(jq -r '.drover.mode // empty' "$(reg)") != corral ]] && return 0
  inside || die "drover lives in $(sess); attach (zellij attach $(sess)) or pass --force"
}
agent() { jq -r --arg a "$1" ".agents[\$a].$2 // empty" "$(reg)"; }
repo_root() { git -C "$(jq -r .project "$(reg)")" rev-parse --show-toplevel 2> /dev/null; }
wt_dir() { # one folder per corral beside the repo: <parent>/droverworktrees/<repo>-<HID>
  local r; r=$(repo_root) || return 1
  echo "$(dirname "$r")/droverworktrees/$(basename "$r")-$HID"
}
state() { jq -r '.state // "unknown"' "$ROOT/$HID/status/$1.json" 2>/dev/null || echo unknown; }
banner() { # the corral tab shows it; only the launcher (outside) needs it
  inside && return 0
  local s
  s=$(sess)
  printf '\nSession: %s\nzellij attach %s\n' "$s" "$s"
  [[ $(jq -r '.drover.mode // empty' "$(reg)") != corral ]] || echo "drover: tab drover (detach: Ctrl-o d)"
}
drover_title() { # re-title the drover session (ids recorded by the SessionStart hook)
  local n i t
  n="drover-$(jq -r .slug "$(reg)")-$HID"
  i=$(jq -r '.drover.session_id // .drover_session_id // empty' "$(reg)") t=$(jq -r '.drover.transcript // .drover_transcript // empty' "$(reg)")
  bash "$DIR/drover-title.sh" "$t" "$i" "$n" || echo "drover session unknown: run /rename $n" >&2
}
slugify() { local x=${1#corral-}; x=${x%-"$HID"}; echo "$x"; }
alive() { # 0 alive, 1 dead, 2 unknown (timeout). no pipe from zellij into grep -q: an early exit would give zellij EPIPE and pipefail a false "dead"
  local out line rc=0
  out=$(timeout 10 zellij list-sessions -n 2> /dev/null) || rc=$?
  ((rc != 124)) || return 2 # timed out: unknown, not dead
  line=$(grep -E "^$1 " <<< "$out" || true)
  [[ -n $line && $line != *EXITED* ]]
}

input_box() { # pane: lines between the last two rule lines of the screen (the prompt box)
  local screen
  screen=$(z dump-screen -p "$1" 2> /dev/null) || screen=
  tac <<< "$screen" | awk '/^─{20}/{c++; next} c==1'
}

type_in() { # pane text [verify=1]: paste once, settle, Enter until the input box no longer holds the text
  local pane=$1 text=$2 verify=${3:-1} needle box _
  needle=${text:0:30}
  z paste -p "$pane" "$text" || return 1
  sleep 0.5
  for _ in 1 2 3; do
    z send-keys -p "$pane" Enter || return 1
    [[ $verify == 1 ]] || return 0
    sleep 1
    box=$(input_box "$pane")
    if ! grep -qF -e "$needle" -e "[Pasted text" <<< "$box"; then return 0; fi
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

Messages cost the receiver a full turn: send one only when you are blocked on another agent or have a finished result it needs. No progress updates, acks or thanks; do not reply to a message unless it asks something.
$DIR/drover.sh send $HID <to-id|drover> $id "<one-line message>"
Longer content: write a file in $h and send the path.

When a task is done (or you cannot finish it), report once; this writes $h/reports/$id.md and tells the drover:
$DIR/drover.sh report $HID $id <task-id> done|blocked|failed "<1-3 line summary>" [--changed "<files>"] [--open "<questions>"]
Then stop and wait.
EOF
  jq -n --arg c "$DIR/drover-status.sh" --arg f "$h/status/$id.json" --arg d "$DIR" '{permissions: {allow: ["Bash(\($d)/drover.sh send *)", "Bash(\($d)/drover.sh report *)"]}, hooks: {
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

kq() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; } # KDL string

tab_template() { # tab template body from the user's default layout (bare `pane` -> children); TPL_STOCK=1: stock bars
  local f="$HOME/.config/zellij/layouts/default.kdl"
  if [[ ${TPL_STOCK:-} != 1 && -f $f ]] && grep -qE '^[[:space:]]*pane[[:space:]]*$' "$f"; then
    awk 'NR==FNR { if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) last = FNR; next }
      FNR == last { next }
      !started && /^[[:space:]]*layout[[:space:]]*\{/ { started = 1; next }
      { print }' "$f" "$f" | sed -E 's/^[[:space:]]*pane[[:space:]]*$/children/'
  else
    printf '    pane size=1 borderless=true {\n        plugin location="tab-bar"\n    }\n    children\n    pane size=2 borderless=true {\n        plugin location="status-bar"\n    }\n'
  fi
}

write_layout() { # corral.kdl (whole session), corral-tab.kdl / drover-tab.kdl (single tab, for new-tab --layout)
  # Only the corral tab gets the user's template: third-party bar plugins in every agent tab each take every
  # `zellij pipe` from the agents' hooks and stall the server. Drover and agent tabs get the stock bars.
  local h="$ROOT/$HID" tpl full dash dcwd corral drover=
  tpl=$(TPL_STOCK=1 tab_template) full=$(tab_template)
  dash=$(kq "$DIR/drover-dashboard.sh $HID")
  dcwd=$(kq "$(jq -r '.drover_cwd' "$(reg)")")
  corral=$(printf '    corral_tab name="corral" {\n        pane name="corral" command="watch" {\n            args "-t" "-n2" %s\n        }\n    }' "$dash")
  if [[ $(jq -r '.drover.mode // empty' "$(reg)") == corral ]]; then
    drover=$(printf '    tab name="drover" focus=true cwd=%s {\n        pane name="drover" command="bash" close_on_exit=true focus=true {\n            args %s\n        }\n    }' "$dcwd" "$(kq "$h/drover-launch.sh")")
    printf 'layout {\n    default_tab_template {\n%s\n    }\n%s\n}\n' "$tpl" "$drover" > "$h/drover-tab.kdl"
  fi
  printf 'layout {\n    default_tab_template {\n%s\n    }\n    tab_template name="corral_tab" {\n%s\n    }\n%s\n}\n' "$tpl" "$full" "$corral" > "$h/corral-tab.kdl"
  printf 'layout {\n    default_tab_template {\n%s\n    }\n    tab_template name="corral_tab" {\n%s\n    }\n%s\n%s\n}\n' "$tpl" "$full" "$corral" "$drover" > "$h/corral.kdl"
}

write_drover_files() { # settings, launcher and prompts of the in-corral drover
  local h="$ROOT/$HID" m sid lsid fork title proj brief=
  [[ $(jq -r '.drover.mode // empty' "$(reg)") == corral ]] || return 0
  m=$(jq -r .drover.model "$(reg)") sid=$(jq -r .drover.session_id "$(reg)") fork=$(jq -r '.drover.fork' "$(reg)")
  lsid=$(jq -r '.launcher_session_id // empty' "$(reg)") proj=$(jq -r .project "$(reg)")
  title="drover-$(jq -r .slug "$(reg)")-$HID"
  [[ ! -f $h/brief.md ]] || brief="Task brief: read $h/brief.md and continue from it."
  jq -n --arg c "$DIR/drover-status.sh" --arg f "$h/status/drover.json" --arg d "$DIR" '{permissions: {allow: ["Bash(\($d)/drover.sh *)"]}, hooks: {
    UserPromptSubmit: [{hooks: [{type: "command", command: "\($c) busy \($f)"}]}],
    Stop: [{hooks: [{type: "command", command: "\($c) idle \($f)"}]}],
    Notification: [{matcher: "permission_prompt|elicitation_dialog", hooks: [{type: "command", command: "\($c) blocked \($f)"}]}],
    PostToolUse: [{hooks: [{type: "command", command: "\($c) unblock \($f)"}]}]}}' > "$h/drover.settings.json"
  if [[ $fork == true ]]; then
    cat > "$h/drover.prompt.first" <<EOF
You are a FORK of the conversation that launched this corral. That conversation's last step, drover.sh new, has ALREADY completed: it created this zellij session, this tab and the dashboard. You are now the drover of HID $HID (session $(jq -r .session "$(reg)"), project $proj).
Do NOT run drover.sh new or close, and do not repeat or resume any tool call from the forked history. Load the ferenyl-claude:drover skill, take the user's request and the decisions from the conversation above, and continue as the drover with drover.sh spawn. $brief
EOF
  else
    cat > "$h/drover.prompt.first" <<EOF
You are the drover of HID $HID (zellij session $(jq -r .session "$(reg)"), project $proj). The session, this tab and the dashboard already exist: do NOT run drover.sh new or close. Load the ferenyl-claude:drover skill and act as the drover. ${brief:-The user will give you the task here.}
EOF
  fi
  cat > "$h/drover.prompt.revive" <<EOF
This corral (HID $HID) was closed or its drover exited, and has been revived. Do NOT run drover.sh new or close. Load the ferenyl-claude:drover skill, catch up from $h/tasks.json, $h/reports/, the tail of $h/inbox/drover.log and drover.sh status $HID, then continue as the drover.
EOF
  {
    echo '#!/usr/bin/env bash'
    printf 'h=%q sid=%q lsid=%q fork=%q m=%q title=%q cwd=%q hid=%q\n' "$h" "$sid" "$lsid" "$fork" "$m" "$title" "$(jq -r .drover_cwd "$(reg)")" "$HID"
    cat <<'EOS'
echo $$ > "$h/drover.pid"
cd "$cwd" || exit 1
for _ in $(seq 40); do # a 1x1 pane blocks claude on write; wait for a real size
  read -r r c < <(stty size 2> /dev/null) || true
  ((${r:-0} > 5 && ${c:-0} > 20)) && break
  sleep 0.25
done
cmd=(env DROVER_HID="$hid" CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude --model "$m" -n "$title" --settings "$h/drover.settings.json")
if compgen -G "$HOME/.claude/projects/*/$sid.jsonl" > /dev/null; then
  exec "${cmd[@]}" --resume "$sid" "$(< "$h/drover.prompt.revive")"
elif [[ $fork == true ]]; then
  exec "${cmd[@]}" --resume "$lsid" --fork-session --session-id "$sid" "$(< "$h/drover.prompt.first")"
else
  exec "${cmd[@]}" --session-id "$sid" "$(< "$h/drover.prompt.first")"
fi
EOS
  } > "$h/drover-launch.sh"
  chmod +x "$h/drover-launch.sh"
}

wait_tabs() { # the layout is applied asynchronously after attach --create-background; 1 if it never shows
  local t _ want='any(.[]; .name=="corral")'
  [[ $(jq -r '.drover.mode // empty' "$(reg)") != corral ]] || want="$want and any(.[]; .name==\"drover\")"
  for _ in $(seq 20); do
    t=$(z list-tabs -j 2> /dev/null) || t=
    [[ -z $t ]] || ! jq -e "$want" <<< "$t" > /dev/null 2>&1 || return 0
    sleep 0.5
  done
  return 1
}

start_session() { # name proj: create the session from corral.kdl; the user's default layout is not guaranteed to convert, so retry with the stock bars
  local s=$1 proj=$2 h="$ROOT/$HID" try
  for try in user stock; do
    if [[ $try == stock ]]; then
      timeout 10 zellij kill-session "$s" 2> /dev/null || true
      timeout 10 zellij delete-session "$s" 2> /dev/null || true
      TPL_STOCK=1 write_layout
    fi
    (cd "$proj" && "${SERVER_ENV[@]}" timeout 10 zellij -n "$h/corral.kdl" attach --create-background "$s") || true
    if wait_tabs; then
      "$DIR/drover-ghost.sh" start "$HID"
      return 0
    fi
  done
  die "corral tabs did not appear"
}

store_ids() { # tab ids by name (tab 0 is only guaranteed at creation)
  local t; t=$(z list-tabs -j)
  # shellcheck disable=SC2016
  jset --argjson t "$t" '.corral_tab_id = ([$t[] | select(.name == "corral")][0].tab_id)
    | if .drover then .drover.tab_id = ([$t[] | select(.name == "drover")][0].tab_id) else . end'
}

move_to() { # tab_id position: move-tab wraps at 0, so re-read the position every step and stop on arrival
  local t=$1 want=$2 tabs pos n _
  tabs=$(z list-tabs -j) || return 0
  n=$(jq length <<< "$tabs")
  for _ in $(seq $((n + 1))); do
    tabs=$(z list-tabs -j) || return 0
    pos=$(jq -r --argjson t "$t" '.[] | select(.tab_id == $t) | .position' <<< "$tabs")
    [[ -n $pos && $pos != "$want" ]] || return 0
    z move-tab --tab-id "$t" "$([[ $pos -gt $want ]] && echo left || echo right)" || return 0
  done
}

order_tabs() { # corral at position 0, drover at position 1
  local cid did
  cid=$(jq -r '.corral_tab_id // empty' "$(reg)") did=$(jq -r '.drover.tab_id // empty' "$(reg)")
  [[ -z $cid ]] || move_to "$cid" 0
  [[ -z $did ]] || move_to "$did" 1
}

drover_running() { # pid file + cmdline: no pgrep, it would match wrapper command lines. Not the sid: /clear rebinds it.
  local h="$ROOT/$HID" pid cmdline
  [[ -r $h/drover.pid ]] || return 1
  pid=$(< "$h/drover.pid")
  kill -0 "$pid" 2> /dev/null || return 1
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null) || return 1
  [[ $cmdline == *"$h/drover.settings.json"* || $cmdline == *"$h/drover-launch.sh"* ]] # claude, or the launcher while it starts
}

ensure_drover() { # recreate the drover tab at position 1 if the tab or its claude is gone
  local h="$ROOT/$HID" did tabs id
  [[ $(jq -r '.drover.mode // empty' "$(reg)") == corral ]] || return 0
  (
    flock 7
    tabs=$(z list-tabs -j) || exit 0
    did=$(jq -r '.drover.tab_id // empty' "$(reg)")
    if [[ -n $did ]] && jq -e --argjson t "$did" 'any(.[]; .tab_id == $t)' <<< "$tabs" > /dev/null; then
      if drover_running; then exit 0; fi
      z close-tab-by-id "$did" 2> /dev/null || true
    fi
    id=$(z new-tab --layout "$h/drover-tab.kdl" --name drover --no-focus) || { echo "could not create the drover tab" >&2; exit 0; }
    # shellcheck disable=SC2016
    jset --argjson t "$id" '.drover.tab_id = $t | del(.drover.gone_notified)'
  ) 7> "$h/drover.lock"
  order_tabs
}

trusted() { jq -e --arg d "$1" '.projects[$d].hasTrustDialogAccepted == true' ~/.claude.json > /dev/null 2>&1; }

# shellcheck disable=SC2178
cmd=${1:-}; shift || true
FORCE=0
if [[ ${2:-} == --force ]]; then # drover.sh <cmd> <HID> --force ...
  FORCE=1
  set -- "$1" "${@:3}"
fi
# shellcheck disable=SC2128
case $cmd in
  new) # new <slug> <project-dir> [--model M] [--brief FILE] [--fork]
    slug=$1 proj=$(realpath "$2")
    shift 2
    # shellcheck disable=SC1007
    model=sonnet brief= fork=false
    while (($#)); do
      case $1 in
        --model) model=${2:?--model needs a value}; shift 2 ;;
        --brief) brief=${2:?--brief needs a file}; shift 2 ;;
        --fork) fork=true; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ -z $brief || -f $brief ]] || die "no such brief: $brief"
    dsid=${DROVER_SESSION_ID:-}
    if [[ -z $dsid ]]; then
      f="$ROOT/sessions/$(printf %s "$PWD" | md5sum | cut -c1-12).json"
      dsid=$(jq -r '.session_id // empty' "$f" 2> /dev/null || true)
    fi
    [[ $fork == false || -n $dsid ]] || die "--fork: this session's id is unknown (no SessionStart hook record)"
    HID=$(cut -c1-8 /proc/sys/kernel/random/uuid)
    slug=$(slugify "$slug") S="corral-$slug-$HID"
    h="$ROOT/$HID"
    mkdir -p "$h"/{agents,status,reports,inbox}
    jq -n --arg id "$HID" --arg s "$S" --arg sl "$slug" --arg p "$proj" --arg o "$PWD" --arg l "$dsid" --arg m "$model" \
      --arg sid "$(cat /proc/sys/kernel/random/uuid)" --argjson f "$fork" \
      '{id: $id, session: $s, project: $p, slug: $sl, drover_cwd: $o, closed: false, agents: {}, launcher_session_id: $l,
        drover: {mode: "corral", model: $m, session_id: $sid, fork: $f}}' > "$h/registry.json"
    echo '[]' > "$h/tasks.json"
    [[ -z $brief ]] || cp "$brief" "$h/brief.md"
    write_drover_files
    write_layout
    start_session "$S" "$proj"
    store_ids
    order_tabs
    echo "HID=$HID"
    banner
    echo "The drover runs inside the corral (tab drover). Attach with the command above; this session can be closed."
    ;;
  spawn) # spawn <hid> <id> <model> <tab|pane:<agent>> <cwd> <purpose> <first task> [--trust]
    HID=$1 id=$2 model=$3 where=$4 cwd=$(realpath "$5") purpose=$6 task=$7 trust=${8:-}
    guard_outside
    [[ -z $(agent "$id" pane_id) ]] || die "agent exists: $id"
    if ! trusted "$cwd" && [[ $trust != --trust ]]; then
      echo "UNTRUSTED $cwd — ask the user, then run again with --trust" >&2; exit 3
    fi
    write_files "$id" "$purpose"
    csid=$(cat /proc/sys/kernel/random/uuid)
    read -r tab pane < <(launch "$id" "$where" "$cwd" "$model" -- --session-id "$csid" "$task")
    # shellcheck disable=SC2015,SC2016
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
  report) # report <hid> <agent-id> <task-id> <done|blocked|failed> <summary> [--changed X] [--open Y] — agents
    HID=$1 id=$2 tid=$3 st=$4 sum=$5 changed=- open=-
    shift 5
    while (($#)); do
      case $1 in
        --changed) changed=${2:?--changed needs a value}; shift 2 ;;
        --open) open=${2:?--open needs a value}; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ $st =~ ^(done|blocked|failed)$ ]] || die "status must be done|blocked|failed"
    printf 'task: %s | status: %s | changed: %s | summary: %s | open: %s\n' "$tid" "$st" "$changed" "$sum" "$open" > "$ROOT/$HID/reports/$id.md"
    send drover "$id" "report: $tid $st"
    echo "reported: $tid $st"
    ;;
  task) # task <hid> set <task-id> key=value... attempts+ | task <hid> next
    HID=$1 t="$ROOT/$HID/tasks.json"
    case ${2:-} in
      next) # not done, not running, all deps done
        jq -r '[.[] | select(.state == "done") | .id] as $d | .[]
          | select(.state != "done" and .state != "in_progress" and all(.depends_on[]?; IN($d[])))
          | "\(.id)\t\(.owner // "-")\t\(.title)"' "$t"
        ;;
      set)
        guard_outside
        tid=${3:?task id}
        shift 3
        jq -e --arg i "$tid" 'any(.[]; .id == $i)' "$t" > /dev/null || die "unknown task: $tid"
        sets='{}' inc=false
        for kv in "$@"; do
          case $kv in
            attempts+) inc=true ;;
            *=*) sets=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<< "$sets") ;;
            *) die "expected key=value or attempts+: $kv" ;;
          esac
        done
        # shellcheck disable=SC2016
        tset --arg i "$tid" --argjson s "$sets" --argjson inc "$inc" \
          '(.[] | select(.id == $i)) |= (. + $s | if $inc then .attempts = ((.attempts // 0) + 1) else . end)'
        jq -r --arg i "$tid" '.[] | select(.id == $i) | "\(.id) \(.state) \(.owner // "-") attempts \(.attempts // 0)"' "$t"
        a=$(jq -r --arg i "$tid" '.[] | select(.id == $i) | .attempts // 0' "$t")
        if ((a >= 3)); then
          echo "max attempts: ask the user"
        elif ((a == 2)); then
          echo "hint: suggest the next larger model"
        fi
        ;;
      *) die "task <HID> set <task-id> key=value... [attempts+] | task <HID> next" ;;
    esac
    ;;
  catchup) # catchup <hid> — recent inbox, dashboard, reports newest first
    HID=$1 h="$ROOT/$HID"
    echo "== inbox =="
    tail -n 20 "$h/inbox/drover.log" 2> /dev/null || true
    echo
    { "$DIR/drover-dashboard.sh" "$HID" || true; } | sed '/^== recent messages ==/,$d' # the inbox tail above covers them
    echo "== reports =="
    # shellcheck disable=SC2012
    ls -lt --time-style=+%H:%M "$h/reports" 2> /dev/null | awk 'NR > 1 { print $6, $7 }'
    ;;
  inbox) # inbox <hid> — follow new inbox lines (for Monitor)
    HID=$1 f="$ROOT/$1/inbox/drover.log"
    touch "$f"
    exec tail -n0 -F "$f"
    ;;
  model) # model <hid> <id> <model>
    HID=$1 id=$2 model=$3
    guard_outside
    wait_idle "$id"
    type_in "$(agent "$id" pane_id)" "/model $model" || die "/model not delivered to $id"
    sleep 2
    # shellcheck disable=SC2016
    jset --arg a "$id" --arg m "$model" '.agents[$a].model = $m'
    echo "$id -> $model"
    banner
    ;;
  move) # move <hid> <id> <tab|pane:<agent>>
    HID=$1 id=$2 where=$3
    guard_outside
    wait_idle "$id"
    sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
    sid=${sid:-$(agent "$id" claude_session_id)}
    cwd=$(agent "$id" cwd) model=$(agent "$id" model)
    close_agent_pane "$id"
    write_files "$id" "$(agent "$id" purpose)"
    read -r tab pane < <(launch "$id" "$where" "$cwd" "$model" -- --resume "$sid")
    # shellcheck disable=SC2015
    tn=$([[ $where == tab ]] && echo "$id" || agent "${where#pane:}" tab_name)
    # shellcheck disable=SC2016
    jset --arg a "$id" --argjson t "$tab" --arg pn "$pane" --arg c "$sid" --arg tn "$tn" \
      '.agents[$a] += {tab_id: $t, tab_name: $tn, pane_id: $pn, claude_session_id: $c}'
    echo "$id -> $pane (tab $tab)"
    banner
    ;;
  worktree) # worktree <hid> <id> [base] — prints the path to use as spawn cwd
    HID=$1 id=$2 base=${3:-HEAD}
    guard_outside
    d=$(wt_dir) || die "project is not a git repo"
    mkdir -p "$d"
    git -C "$(repo_root)" worktree add -b "drover/$HID/$id" "$d/$id" "$base" > /dev/null
    echo "$d/$id"
    ;;
  worktrees) # worktrees <hid> — path, branch, dirty|clean
    HID=$1
    d=$(wt_dir) || exit 0
    [[ -d $d ]] || exit 0
    for w in "$d"/*/; do
      [[ -d $w ]] || continue
      w=${w%/}
      b=$(git -C "$w" branch --show-current 2> /dev/null)
      [[ -n $(git -C "$w" status --porcelain 2> /dev/null) ]] && st=dirty || st=clean
      echo "$w $b $st"
    done
    ;;
  kill) # kill <hid> <id>
    HID=$1 id=$2
    guard_outside
    close_agent_pane "$id"
    # shellcheck disable=SC2016
    jset --arg a "$id" 'del(.agents[$a])'
    echo "closed: $id"
    banner
    ;;
  rename) # rename <hid> <slug>
    HID=$1 slug=$(slugify "$2")
    guard_outside
    new="corral-$slug-$HID"
    [[ $new != "$(sess)" ]] || die "session is already named $new"
    taken=$(timeout 10 zellij list-sessions -s 2> /dev/null) || true
    ! grep -qx -- "$new" <<< "$taken" || die "session name taken: $new"
    z rename-session "$new"
    # shellcheck disable=SC2016
    jset --arg s "$new" --arg sl "$slug" '.session = $s | .slug = $sl'
    drover_title
    banner
    ;;
  flush) # flush <hid> <id> — deliver messages queued while the agent was blocked
    HID=$1 id=$2 q="$ROOT/$HID/queue/$2.txt"
    guard_outside
    [[ -s $q ]] || die "nothing queued for $id"
    [[ $(state "$id") != blocked ]] || die "$id is still blocked"
    # shellcheck disable=SC2094
    while IFS=$'\t' read -r -u 3 f m; do
      type_in "$(agent "$id" pane_id)" "[from $f] $m" || die "not delivered to $id (undelivered lines kept)"
      sed -i 1d "$q"
    done 3< "$q"
    rm -f "$q"
    echo "flushed: $id"
    ;;
  read) # read <hid> <id> [lines]
    HID=$1 id=$2
    if [[ $id == drover ]]; then
      pane=$(z list-panes -j -t | jq -r --argjson t "$(jq -r '.drover.tab_id // empty' "$(reg)")" '[.[] | select(.tab_id==$t and .is_plugin==false)][0].id | "terminal_\(.)"')
    else
      pane=$(agent "$id" pane_id)
    fi
    [[ -n $pane && $pane != terminal_null ]] || die "unknown agent: $id"
    z dump-screen -p "$pane" | tail -n "${3:-40}"
    ;;
  revive) # revive <hid> — recreate session if dead, restore the drover tab, relaunch all agents with --resume
    HID=$1 s=$(sess) proj=$(jq -r .project "$(reg)")
    h="$ROOT/$HID"
    rc=0
    alive "$s" || rc=$?
    ((rc != 2)) || die "zellij unresponsive"
    jset 'del(.closing_at) | del(.shutdown)'
    rm -f "$h/close.done"
    write_drover_files
    write_layout
    if ((rc == 1)); then
      timeout 10 zellij delete-session "$s" 2> /dev/null || true
      start_session "$s" "$proj"
      store_ids
    else
      if ! kill -0 "$(sed -n 2p "$h/ghost.pids" 2> /dev/null)" 2> /dev/null; then
        "$DIR/drover-ghost.sh" stop "$HID"
        "$DIR/drover-ghost.sh" start "$HID"
      fi
      ensure_drover
    fi
    order_tabs
    jset '.closed = false'
    for id in $(jq -r '.agents | keys[]' "$(reg)"); do
      [[ -z $(z list-panes -j -t | jq -r --arg p "$(agent "$id" pane_id)" '.[] | select("terminal_\(.id)" == $p) | .id') ]] || continue
      sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
      sid=${sid:-$(agent "$id" claude_session_id)}
      write_files "$id" "$(agent "$id" purpose)"
      read -r tab pane < <(launch "$id" tab "$(agent "$id" cwd)" "$(agent "$id" model)" -- --resume "$sid")
      # shellcheck disable=SC2016
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
  close) # close <hid> [--remove-worktrees|--keep-worktrees] — detached: the drover may live inside the session it kills
    HID=$1 s=$(sess) h="$ROOT/$HID"
    case ${2:-} in
      --remove-worktrees) rmwt=true ;;
      --keep-worktrees) rmwt=false ;;
      '')
        rmwt=false
        wts=$("$DIR/drover.sh" worktrees "$HID")
        if [[ -n $wts ]]; then
          echo "$wts"
          echo "worktrees exist: ask the user, then close $HID --remove-worktrees or --keep-worktrees" >&2
          exit 4
        fi
        ;;
      *) die "unknown option: $2" ;;
    esac
    # shellcheck disable=SC2016
    jset --argjson t "$(date +%s)" --argjson w "$rmwt" '.closing_at = $t | .remove_worktrees = $w'
    rm -f "$h/close.done"
    "$DIR/drover-ghost.sh" stop "$HID"
    echo "closing $s"
    setsid -f "$DIR/drover.sh" _close "$HID" < /dev/null > "$h/close.log" 2>&1
    if inside; then
      echo "this drover exits with the session"
    else
      for _ in $(seq 120); do [[ -f $h/close.done ]] && break; sleep 0.5; done
      if [[ -f $h/close.done ]]; then echo "shut down: $s"; else echo "still closing, see $h/close.log" >&2; fi
    fi
    ;;
  _close) # internal: runs detached from close
    HID=$1 s=$(sess) h="$ROOT/$HID"
    trap 'jset "del(.closing_at)"' ERR
    pat="^(.*/)?zellij --server .*/corral-[^/]*-$HID\$" # session may have been renamed; the HID suffix never changes
    "$DIR/drover-ghost.sh" stop "$HID"
    sleep 1
    timeout 10 zellij kill-session "$s" 2> /dev/null || true
    for _ in $(seq 20); do
      pgrep -f "$pat" > /dev/null || break
      sleep 0.5
    done
    if pgrep -f "$pat" > /dev/null; then
      pkill -TERM -f "$pat" || true
      sleep 2
      pkill -KILL -f "$pat" || true
    fi
    timeout 10 zellij delete-session "$s" 2> /dev/null || true
    if jq -e '.remove_worktrees == true' "$(reg)" > /dev/null && d=$(wt_dir) && [[ -d $d ]]; then
      for w in "$d"/*/; do
        [[ -d $w ]] && git -C "$(repo_root)" worktree remove --force "${w%/}" || true
      done
      git -C "$(repo_root)" worktree prune || true
      rmdir "$d" "$(dirname "$d")" 2> /dev/null || true
    fi
    jset '.closed = true | .shutdown = true | del(.closing_at) | del(.remove_worktrees) | .agents = {}'
    touch "$h/close.done"
    echo "shut down: $s"
    command -v notify-send > /dev/null && notify-send "drover: $s shut down" || true
    ;;
  _order) HID=$1; order_tabs ;; # internal: watcher
  _recreate_corral) # internal: watcher — the dashboard only, never the drover
    HID=$1
    id=$(z new-tab --layout "$ROOT/$HID/corral-tab.kdl" --name corral --no-focus)
    # shellcheck disable=SC2016
    jset --argjson t "$id" '.corral_tab_id = $t'
    order_tabs
    ;;
  _drover_gone) # internal: watcher — tell once that the drover tab is missing
    HID=$1
    if ! jq -e '.closed or (.drover.gone_notified // false)' "$(reg)" > /dev/null; then
      jset '.drover.gone_notified = true'
      echo "[drover-sh -> drover] drover tab gone — run drover.sh revive $HID" >> "$ROOT/$HID/inbox/drover.log"
      command -v notify-send > /dev/null && notify-send "drover: $(sess)" "drover tab gone, run drover.sh revive $HID" || true
    fi
    ;;
  *) die "commands: new spawn send report task catchup inbox model move kill worktree worktrees rename flush read revive status close (mutating commands: <cmd> <HID> --force ...)" ;;
esac
