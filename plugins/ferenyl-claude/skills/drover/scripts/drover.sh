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

# shellcheck source=lib.sh
. "$DIR/lib.sh"
reg() { echo "$ROOT/$HID/registry.json"; }
sess() { jq -r .session "$(reg)"; }
z() { timeout 10 zellij -s "$(sess)" action "$@"; }
jset() { jfile "$(reg)" "$@"; }
tset() { jfile "$ROOT/$HID/tasks.json" "$@"; }
inside() { [[ ${DROVER_HID:-} == "$HID" ]]; }
guard_outside() { # the drover lives in its corral; other sessions must not drive it
  [[ $FORCE == 1 || $(jq -r '.drover.mode // empty' "$(reg)") != corral ]] && return 0
  inside || die "drover lives in $(sess); attach (zellij attach $(sess)) or pass --force"
}
agent() { jq -r --arg a "$1" ".agents[\$a].$2 // empty" "$(reg)"; }
story_derive() { [[ ! -f $ROOT/$HID/stories.json ]] || "$DIR/drover-story.sh" "$HID" derive || true; }
has_story() { jq -e --arg s "$1" 'any(.[]; .id == $s)' "$ROOT/$HID/stories.json" > /dev/null 2>&1 || die "unknown story: $1"; }
repo_root() { git -C "${REPO:-$(jq -r .project "$(reg)")}" rev-parse --show-toplevel 2> /dev/null; }
repos() { # every repo this corral has worktrees in: the project's, then those given with worktree --repo
  { REPO='' repo_root || true; jq -r '.repos[]?' "$(reg)"; } | awk 'NF && !seen[$0]++'
}
branch_of() { jq -r --arg a "$1" --arg d "drover/$HID/$1" '.branches[$a] // $d' "$(reg)"; } # worktree --branch name, else drover/<HID>/<id>
default_base() { # the repo's default branch (origin/HEAD), HEAD if unknown
  git -C "$(repo_root)" symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null || echo HEAD
}
find_repo() { # id: set REPO to the repo holding the agent's worktree or branch, unless --repo was given
  local x
  [[ -z ${REPO:-} ]] || return 0
  for x in $(repos); do
    if [[ -d $(REPO=$x wt_dir)/$1 ]] || git -C "$x" show-ref --verify --quiet "refs/heads/$(branch_of "$1")"; then REPO=$x; return 0; fi
  done
}
wt_dir() { # one folder per corral beside the repo: <parent>/droverworktrees/<repo>-<HID>
  local r; r=$(repo_root) || return 1
  echo "$(dirname "$r")/droverworktrees/$(basename "$r")-$HID"
}
state() { jq -r '.state // "unknown"' "$ROOT/$HID/status/$1.json" 2> /dev/null | grep . || echo unknown; }
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
valid_id() { [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$2 must match [a-z0-9][a-z0-9-]*: $1"; }
trim() { local x=$1; x=${x#"${x%%[![:space:]]*}"}; echo "${x%"${x##*[![:space:]]}"}"; }
slugify() { local x=${1#corral-}; x=${x%-"$HID"}; echo "$x"; }

input_box() { # pane: lines between the last two rule lines of the screen (the prompt box)
  local screen
  screen=$(z dump-screen -p "$1" 2> /dev/null) || screen=
  tac <<< "$screen" | awk '/^─{20}/{c++; next} c==1'
}

box_has_text() { # pane: the input box holds typed text (the empty box is "❯" + nbsp; the placeholder hint Try "…" counts as empty)
  input_box "$1" | sed -E $'s/^[[:space:]]*(❯|>)?([[:space:]]|\xc2\xa0)*//; s/^Try ".*$//' | grep -q .
}

type_in() { # pane text [verify=1 [guard=0]]: one writer per pane at a time; guard=1: exit 3 if the user is typing in the box
  mkdir -p "$ROOT/$HID/locks"
  ( flock -w 30 9 || exit 1; _type_in "$@" ) 9> "$ROOT/$HID/locks/$1.lock"
}
_type_in() { # pane text [verify=1]: paste once, settle, Enter until the input box no longer holds the text
  local pane=$1 text=$2 verify=${3:-1} guard=${4:-0} needle box _
  ((${#text} > 30)) && needle=${text: -30} || needle=$text # a negative offset past the start gives "" in bash
  needle=$(tr -d '[:space:]' <<< "$needle") # the tail differs between messages (the heads all start "[from x]"); box lines wrap, so compare without whitespace
  [[ $guard != 1 ]] || ! box_has_text "$pane" || return 3 # inside the lock: no window between the check and the paste
  z paste -p "$pane" "$text" || return 1
  sleep 0.5
  for _ in 1 2 3; do
    z send-keys -p "$pane" Enter || return 1
    [[ $verify == 1 ]] || return 0
    sleep 1
    box=$(input_box "$pane")
    if ! tr -d '[:space:]' <<< "$box" | grep -qF -e "$needle" -e "[Pastedtext"; then return 0; fi
  done
  return 1
}

relaunch() { # id: restart the agent with --resume in its place (PERM, purpose and story from the registry)
  local id=$1 sid old tab pane
  [[ -n $(agent "$id" pane_id) ]] || die "unknown agent: $id"
  wait_idle "$id"
  sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
  sid=${sid:-$(agent "$id" claude_session_id)}
  old=$(agent "$id" pane_id)
  type_in "$old" "/exit" 0 || true
  sleep 2
  write_files "$id" "$(agent "$id" purpose)" "$(agent "$id" story)"
  read -r tab pane < <(launch "$id" "pane:$id" "$(agent "$id" cwd)" "$(agent "$id" model)" -- --resume "$sid")
  z close-pane -p "$old" 2> /dev/null || true
  # shellcheck disable=SC2016
  jset --arg a "$id" --arg pn "$pane" --arg c "$sid" '.agents[$a] += {pane_id: $pn, claude_session_id: $c}'
}
watcher_alive() { # a drover `inbox` (Monitor) is running: pid file + kill -0
  local p
  p=$(cat "$ROOT/$HID/inbox/pid" 2> /dev/null) || return 1
  [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2> /dev/null
}
inbox_hint() { watcher_alive || echo "no live inbox watcher — re-arm Monitor: drover.sh inbox $HID" >&2; }

send() { # to from msg
  local to=$1 from=$2 msg=$3 h="$ROOT/$HID" line pane rc
  from=${from//$'\n'/ } msg=${msg//$'\n'/ } # one log line per message: no forged "[droverstatusui -> ...]" lines
  line="[$from -> $to] $msg"
  [[ ${from,,} != droverstatusui || -z ${DROVER_AGENT:-} ]] || die "droverstatusui is the web user; agents must not send as it"
  [[ ${from,,} != drover || -z ${DROVER_AGENT:-} ]] || die "agents must not send as drover"
  [[ $from != drover || $to == drover || $to == droverstatusui || -n ${DROVER_AGENT:-} ]] || inbox_hint
  if [[ $to == droverstatusui ]]; then # the web GUI is not an agent: log only, the dashboard reads messages.log
    :
  elif [[ $to == drover ]]; then
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
    rc=0
    type_in "$pane" "[from $from] $msg" 1 1 || rc=$?
    if ((rc == 3)); then # the user is typing in its input box
      echo "$(date -Is) $line (skipped: input box in use)" >> "$h/messages.log"
      [[ $from == drover ]] || echo "[drover-sh -> drover] not delivered to $to (its input box holds text, the user is typing): $msg. Retry later, as $from: send $HID $to $from \"...\"" >> "$h/inbox/drover.log" # the drover gets exit 3 on stderr
      echo "not delivered to $to (input box in use)" >&2
      return 3
    fi
    ((rc == 0)) || die "not delivered to $to"
    [[ $(state "$to") != idle ]] || echo '{}' | "$DIR/drover-status.sh" busy "$h/status/$to.json" # shown busy at once, not when the hook gets to run
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

docs_sync() { # [agent] [note] [changed]: copy user documents among <changed> from the corral folder into docs/, register every unregistered file in docs/ in docs.json
  local h="$ROOT/$HID" a=${1:-} note=${2:-} changed=${3:-} f p rel cwd
  local dd="$h/docs" dj="$h/docs.json"
  mkdir -p "$dd"
  [[ -f $dj ]] || echo '[]' > "$dj"
  cwd=$( [[ -z $a ]] || agent "$a" cwd)
  for f in ${changed//,/ }; do
    [[ $f == /* ]] || f=${cwd:-$h}/$f
    p=$(realpath -m "$f") rel=${p#"$h"/}
    [[ $p == "$h"/* && -f $p ]] || continue
    case $rel in
      docs/* | agents/* | status/* | reports/* | inbox/* | queue/* | locks/* | stories/* | brief.md | plan.md | rules.md | *.json | *.log | *.kdl | *.lock | *.sh | *.pid | *.prompt* | *.done) continue ;;
    esac
    [[ -e $dd/$rel ]] && ! cmp -s "$p" "$dd/$rel" && { echo "docs/$rel exists with other content, not copied: $p" >&2; continue; }
    mkdir -p "$(dirname "$dd/$rel")" && cp "$p" "$dd/$rel"
  done
  find "$dd" -type f -printf '%P\n' 2> /dev/null | sort | while read -r f; do
    jq -e --arg p "$dd/$f" 'any(.[]?; .path == $p)' "$dj" > /dev/null 2>&1 && continue
    # shellcheck disable=SC2016
    jfile "$dj" --arg p "$dd/$f" --arg n "${note:-$f}" --arg a "$a" '. + [{path: $p, note: $n, agent: $a, added_at: (now | todate)}]'
  done
}

close_show() { # close the floating pane opened by the last `show` (if still open)
  local p
  p=$(jq -r '.drover.show_pane // empty' "$(reg)")
  [[ -n $p ]] || return 0
  z close-pane -p "$p" 2> /dev/null || true
  jset 'del(.drover.show_pane)'
}

# shellcheck disable=SC2016
task_mark() { # task-id agent: the task is running for agent (call after delivery succeeded); each dispatch restarts it
  tset --arg i "$1" --arg o "$2" '(.[] | select(.id == $i)) |= (.owner = $o | .state = "in_progress" | .attempts = ((.attempts // 0) + 1)
    | .started_at = (now | todate) | del(.finished_at))'
  story_derive > /dev/null
}
# shellcheck disable=SC2016
task_text() { # task-id agent: the message that tells agent its task
  jq -r --arg i "$1" --arg h "$HID" --arg a "$2" '.[] | select(.id == $i)
    | "Task \(.id) (owner \($a)): \(.title)\(if (.acceptance | length) > 0 then ". Acceptance: " + (.acceptance | join("; ")) else "" end)\(if (.approved | length) > 0 then ". Approved by the drover for this task: " + (.approved | join("; ")) else "" end). Report with: drover.sh report \($h) \($a) \(.id) done|blocked|failed \"<summary>\""' "$ROOT/$HID/tasks.json"
}
has_task() { jq -e --arg i "$1" 'any(.[]; .id == $i)' "$ROOT/$HID/tasks.json" > /dev/null 2>&1 || die "unknown task: $1"; }

mcp_config() { # cwd list: --mcp config with only the named servers (user scope, project scope and .mcp.json of the cwd, its repo root and the main worktree); "none" = no servers
  local dirs=("$1") d f pj=() proj='[]' r
  r=$(git -C "$1" rev-parse --show-toplevel 2> /dev/null) && dirs+=("$r")
  r=$(git -C "$1" worktree list --porcelain 2> /dev/null | sed -n '1s/^worktree //p') && [[ -z $r ]] || dirs+=("$r")
  dirs+=("$(jq -r .project "$(reg)")")
  proj=$(printf '%s\n' "${dirs[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | unique')
  for d in $(jq -r '.[]' <<< "$proj"); do [[ ! -f $d/.mcp.json ]] || pj+=("$d/.mcp.json"); done
  f=$(jq -sc '{mcpServers: (map(.mcpServers // {}) | add // {})}' /dev/null "${pj[@]}")
  # shellcheck disable=SC2016
  jq -n --arg l "$2" --argjson dirs "$proj" --slurpfile u "$HOME/.claude.json" --argjson p "$f" '
    ($l | split(",") | map(gsub("\\s"; "")) | map(select(. != "" and . != "none"))) as $n
    | (($u[0].mcpServers // {}) + ([$dirs[] | $u[0].projects[.].mcpServers // {}] | add // {}) + $p.mcpServers) as $all
    | ($n - ($all | keys)) as $miss
    | if ($miss | length) > 0 then ("unknown MCP server \($miss | join(", ")); known: \($all | keys | join(", "))\n" | halt_error(2)) else
      {mcpServers: ($all | with_entries(select(.key | IN($n[]))))} end'
}

flow_patterns() { # step: Bash patterns of the CLI commands that perform it (MCP writes are covered by the prompt rule only)
  case $1 in
    commit) echo 'Bash(git commit *)' ;;
    merge-local) echo 'Bash(git merge *)' ;;
    push | pr-link) echo 'Bash(git push *)' ;;
    pr | pr-draft) printf '%s\n' 'Bash(gh pr create *)' 'Bash(az repos pr create *)' 'Bash(glab mr create *)' ;;
    review-post) printf '%s\n' 'Bash(gh pr review *)' 'Bash(gh pr comment *)' 'Bash(az repos pr reviewer *)' 'Bash(glab mr note *)' ;;
    review-approve) printf '%s\n' 'Bash(gh pr review --approve *)' 'Bash(gh pr review * --approve*)' 'Bash(az repos pr set-vote *)' 'Bash(glab mr approve *)' ;;
    review-fix) printf '%s\n' 'Bash(git commit *)' 'Bash(git push *)' 'Bash(gh pr comment *)' 'Bash(glab mr note *)' ;;
    merge-pr) printf '%s\n' 'Bash(gh pr merge *)' 'Bash(az repos pr update *)' 'Bash(glab mr merge *)' ;;
    tracker-assign) printf '%s\n' 'Bash(gh issue edit *)' 'Bash(az boards work-item update *)' 'Bash(jira issue assign *)' 'Bash(glab issue update *)' ;;
    tracker-status) printf '%s\n' 'Bash(gh issue close *)' 'Bash(gh issue reopen *)' 'Bash(az boards work-item update *)' 'Bash(jira issue move *)' 'Bash(glab issue close *)' ;;
    tracker-comment) printf '%s\n' 'Bash(gh issue comment *)' 'Bash(az boards work-item update *)' 'Bash(jira issue comment *)' 'Bash(glab issue note *)' ;;
    tracker-link) printf '%s\n' 'Bash(gh issue edit *)' 'Bash(az boards work-item relation *)' 'Bash(jira issue link *)' 'Bash(glab issue update *)' ;;
  esac
}

write_files() { # id purpose [story]
  local id=$1 purpose=$2 h="$ROOT/$HID" allow=${ALLOW-$(agent "$1" allow)} cov s fa='' fk='' nf
  cov=" $(flow_steps "${3:-}" | tr '\n' ' ')"
  for s in $FLOW_STEPS; do
    if [[ $cov == *" $s "* ]]; then fa+=$'\n'$(flow_patterns "$s"); else fk+=$'\n'$(flow_patterns "$s"); fi
  done
  nf=$(flow_json "${3:-}" | jq -r '.file // empty')
  cat > "$h/agents/$id.prompt.md" <<EOF
You are agent $id in drover $HID. Purpose: $purpose
Only do what is within your purpose. Edit files only inside your working directory and $h.

Agents (live list, read only if you need to message someone): $h/registry.json

Messages cost the receiver a full turn: send one only when you are blocked on another agent or have a finished result it needs. No progress updates, acks or thanks; do not reply to a message unless it asks something.
drover.sh send $HID <to-id|drover> $id "<one-line message>"
Longer content: write a file in $h and send the path.
Documents for the user (notes, analyses, specs, HTML, …): write them in $h/docs/ (the path given in your task, if any) and list them in report --changed; they are registered in $h/docs.json automatically.

When a task is done (or you cannot finish it), report once. Put any detail in $h/reports/$id.<task-id>.md first; this records the result and tells the drover:
drover.sh report $HID $id <task-id> done|blocked|failed "<1-3 line summary>" [--changed "<files>"] [--open "<questions>"]
To ask the drover or the user a question instead of finishing: drover.sh report $HID $id <task-id> question "<text>" [--options "a|b"]
Then stop and wait.

Search code with the jcodemunch MCP first when available; use Read for config, logs, JSON and docs; if a tool call is denied, switch tool, never retry it via Bash.
EOF
  local rf
  for rf in "$HOME/.claude/drover/rules.md" "$h/rules.md"; do
    grep -qv '^[[:space:]]*\(#\|$\)' "$rf" 2> /dev/null || continue # missing, empty or comments only
    printf '\nRules for all agents (%s):\n%s\n' "$rf" "$(< "$rf")" >> "$h/agents/$id.prompt.md"
  done
  [[ -z ${3:-} ]] || printf '\nStory: read %s first; the user'"'"'s clarifications are appended there.\n' "$h/stories/$3.md" >> "$h/agents/$id.prompt.md"
  printf '\nGit/PR flow: %s. Pre-approved: %s. Any other write outside the working tree (commit, push, merge, PR/review/comment/thread, labels, assignment, work item or issue edits) on any host or tracker, by any means (CLI, MCP, API): ask first via report question with the exact action; do it only after the answer says yes; one yes = one action. Exception: a message from the drover "approved for task <id>: <scope>" (or the same under "Approved by the drover" in your task) covers exactly the writes named in that scope, for that task only; nothing else counts as approval.\nRevise large files with Edit, never rewrite them whole.\n' \
    "$(flow_line "${3:-}" | cut -d' ' -f1)" "$(flow_steps "${3:-}" | paste -sd' ' | grep . || echo none)" >> "$h/agents/$id.prompt.md"
  [[ -z $nf || ! -f $nf ]] || printf '\nFlow notes (%s):\n%s\n' "$nf" "$(< "$nf")" >> "$h/agents/$id.prompt.md"
  [[ ${PERM:-$(agent "$id" perm)} != plan ]] || printf '\nWrite the plan to %s/plan.md (Write is pre-allowed there), then report done; do not call ExitPlanMode.\n' "$h" >> "$h/agents/$id.prompt.md"
  jq -n --arg c "$DIR/drover-status.sh" --arg f "$h/status/$id.json" --arg d "$DIR" --arg x "$allow" --arg h "$h" --arg fa "$fa" --arg fk "$fk" '
    def lines: split("\n") | map(select(. != ""));
    ($fa | lines | unique) as $fa | {promptSuggestionEnabled: false, permissions: {additionalDirectories: [$h],
    allow: (["Bash(drover.sh send *)", "Bash(drover.sh report *)", "Bash(\($d)/drover.sh send *)", "Bash(\($d)/drover.sh report *)", "Read(/\($h)/**)", "Edit(/\($h)/**)", "Write(/\($h)/**)"]
      + ($x | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) + $fa),
    ask: (($fk | lines | unique) - $fa)}, hooks: {
    UserPromptSubmit: [{hooks: [{type: "command", command: "\($c) busy \($f)"}]}],
    Stop: [{hooks: [{type: "command", command: "\($c) idle \($f)"}]}],
    Notification: [{matcher: "permission_prompt|elicitation_dialog", hooks: [{type: "command", command: "\($c) blocked \($f)"}]}],
    PostToolUse: [{hooks: [{type: "command", command: "\($c) unblock \($f)"}]}]}}' > "$h/agents/$id.settings.json"
}

launch() { # id where cwd model -- claude-args...
  local id=$1 where=$2 cwd=$3 model=$4 h="$ROOT/$HID" tab pane target
  shift 5
  trusted_at "$cwd" || ! trusted "$cwd" || trust_dir "$cwd" # a worktree of a trusted repo: claude itself would still ask
  local perm=${PERM:-$(agent "$id" perm)} mcp=()
  [[ ! -f $h/agents/$id.mcp.json ]] || mcp=(--strict-mcp-config --mcp-config "$h/agents/$id.mcp.json") # before another option: --mcp-config takes several values
  local cmd=("${CLEAN_ENV[@]}" "PATH=$DIR:$PATH" DROVER_AGENT=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model "$model" --settings "$h/agents/$id.settings.json"
    ${perm:+--permission-mode "$perm"} "${mcp[@]}" --append-system-prompt-file "$h/agents/$id.prompt.md" -n "$HID/$id" "$@")
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
  jset '.drover.model = "sonnet"' # also for corrals created on another model
  m=sonnet sid=$(jq -r .drover.session_id "$(reg)") fork=$(jq -r '.drover.fork' "$(reg)")
  lsid=$(jq -r '.launcher_session_id // empty' "$(reg)") proj=$(jq -r .project "$(reg)")
  title="drover-$(jq -r .slug "$(reg)")-$HID"
  [[ ! -f $h/brief.md ]] || brief="Task brief: read $h/brief.md and continue from it."
  jq -n --arg c "$DIR/drover-status.sh" --arg f "$h/status/drover.json" --arg d "$DIR" '{promptSuggestionEnabled: false, permissions: {allow: ["Bash(\($d)/drover.sh *)", "Bash(drover.sh *)"]}, hooks: {
    UserPromptSubmit: [{hooks: [{type: "command", command: "\($c) busy \($f)"}]}],
    Stop: [{hooks: [{type: "command", command: "\($c) idle \($f)"}]}],
    Notification: [{matcher: "permission_prompt|elicitation_dialog", hooks: [{type: "command", command: "\($c) blocked \($f)"}]}],
    PostToolUse: [{hooks: [{type: "command", command: "\($c) unblock \($f)"}]}]}}' > "$h/drover.settings.json"
  if [[ $fork == true ]]; then
    cat > "$h/drover.prompt.first" <<EOF
You are a FORK of the conversation that launched this corral. That conversation's last step, drover.sh new, has ALREADY completed: it created this zellij session, this tab and the dashboard. You are now the drover of HID $HID (session $(jq -r .session "$(reg)"), project $proj).
Do NOT run drover.sh new or close, and do not repeat or resume any tool call from the forked history. Load the ferenyl-claude:drover skill, take the user's request and the decisions from the conversation above, and continue as the drover with drover.sh spawn. Start the inbox Monitor (see the skill). $brief
EOF
  else
    cat > "$h/drover.prompt.first" <<EOF
You are the drover of HID $HID (zellij session $(jq -r .session "$(reg)"), project $proj). The session, this tab and the dashboard already exist: do NOT run drover.sh new or close. Load the ferenyl-claude:drover skill and act as the drover (start the inbox Monitor, see the skill). ${brief:-The user will give you the task here.}
EOF
  fi
  cat > "$h/drover.prompt.revive" <<EOF
This corral (HID $HID) was closed or its drover exited, and has been revived. Do NOT run drover.sh new or close. Load the ferenyl-claude:drover skill, catch up from $h/tasks.json, $h/reports/, the tail of $h/inbox/drover.log and drover.sh status $HID, start the inbox Monitor (see the skill), then continue as the drover.
EOF
  {
    echo '#!/usr/bin/env bash'
    printf 'h=%q sid=%q lsid=%q fork=%q m=%q title=%q cwd=%q hid=%q dir=%q\n' "$h" "$sid" "$lsid" "$fork" "$m" "$title" "$(jq -r .drover_cwd "$(reg)")" "$HID" "$DIR"
    cat <<'EOS'
echo $$ > "$h/drover.pid"
cd "$cwd" || exit 1
for _ in $(seq 40); do # a 1x1 pane blocks claude on write; wait for a real size
  read -r r c < <(stty size 2> /dev/null) || true
  ((${r:-0} > 5 && ${c:-0} > 20)) && break
  sleep 0.25
done
cmd=(env "PATH=$dir:$PATH" DROVER_HID="$hid" CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model "$m" -n "$title" --settings "$h/drover.settings.json")
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

trusted_at() { # dir or an ancestor accepted in claude's own config
  local x=$1
  while [[ -n $x && $x != / ]]; do
    ! jq -e --arg d "$x" '.projects[$d].hasTrustDialogAccepted == true' ~/.claude.json > /dev/null 2>&1 || return 0
    x=$(dirname "$x")
  done
  return 1
}

trusted() { # trusted_at, or a git worktree whose main worktree is
  trusted_at "$1" || trusted_at "$(git -C "$1" worktree list --porcelain 2> /dev/null | sed -n '1s/^worktree //p')"
}

trust_dir() { # dir: mark it trusted in ~/.claude.json, so claude shows no trust dialog there
  local f t
  f=$(realpath ~/.claude.json) && t=$(mktemp "$f.drover.XXXXXX") || return 1
  if jq --arg d "$1" '.projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true})' "$f" > "$t"; then mv "$t" "$f"; else rm -f "$t"; return 1; fi
}

# shellcheck disable=SC2178
cmd=${1:-}; shift || true
FORCE=0
if [[ ${2:-} == --force ]]; then # drover.sh <cmd> <HID> --force ...
  FORCE=1
  set -- "$1" "${@:3}"
fi
# shellcheck disable=SC2128
case $cmd in
  ''|new|gc|pref|_*) ;;
  help) ;;
  *) [[ ${1:-} =~ ^[0-9a-f]{8}$ ]] || die "usage: drover.sh <cmd> <HID> … — drover.sh help <cmd>"
     [[ -f $ROOT/$1/registry.json ]] || die "unknown drover id: $1" ;;
esac
# shellcheck disable=SC2128
case $cmd in
  new) # new <slug> <project-dir> [--brief FILE] [--fork]
    slug=$1 proj=$(realpath "$2")
    shift 2
    # shellcheck disable=SC1007
    model=sonnet brief= fork=false # the drover only delegates and waits: planning runs in a planner agent
    while (($#)); do
      case $1 in
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
    slug=$(slugify "${slug,,}") S="corral-$slug-$HID"
    valid_id "$slug" slug
    h="$ROOT/$HID"
    mkdir -p "$h"/{agents,status,reports,inbox,docs}
    jq -n --arg id "$HID" --arg s "$S" --arg sl "$slug" --arg p "$proj" --arg o "$PWD" --arg l "$dsid" --arg m "$model" \
      --arg sid "$(cat /proc/sys/kernel/random/uuid)" --argjson f "$fork" \
      --arg v "$(jq -r '.version // empty' "$DIR/../../../.claude-plugin/plugin.json" 2> /dev/null || true)" \
      '{schema: 1, drover_version: $v, id: $id, session: $s, project: $p, slug: $sl, drover_cwd: $o, closed: false, agents: {}, launcher_session_id: $l,
        drover: {mode: "corral", model: $m, session_id: $sid, fork: $f}}' > "$h/registry.json"
    echo '[]' > "$h/tasks.json"
    : > "$h/messages.log"
    [[ -z $brief ]] || cp "$brief" "$h/brief.md"
    if [[ ! -f $ROOT/rules.md ]]; then
      printf '# Rules for all agents of every corral (added to each agent prompt, before <HID>/rules.md).\n# May widen the default "edit only inside your working directory and the corral folder".\n' > "$ROOT/rules.md"
    fi
    if [[ ! -f $h/rules.md ]] && jq -e '.mcpServers.jcodemunch' "$HOME/.claude.json" > /dev/null 2>&1; then
      echo 'Search code with the jcodemunch MCP first (index the repo if needed); Read only for config, logs, JSON and docs.' > "$h/rules.md"
    fi
    write_drover_files
    write_layout
    start_session "$S" "$proj"
    store_ids
    order_tabs
    echo "HID=$HID"
    banner
    echo "The drover runs inside the corral (tab drover). Attach with the command above; this session can be closed."
    ;;
  spawn) # spawn <hid> <id> <model> <tab|pane:<agent>> <cwd> <purpose> <first task> [--trust] [--story <sid>] [--task <tid>] [--perm <mode>] [--mcp a,b|none] [--allow "Bash(git status *),Bash(git diff *),…"]
    HID=$1 id=$2 model=$3 where=$4 cwd=$(realpath "$5") purpose=$6 task=$7 trust='' story='' tid='' PERM='' ALLOW='' mcps=''
    shift 7
    while (($#)); do
      case $1 in
        --trust) trust=--trust; shift ;;
        --story) story=${2:?--story needs a story id}; shift 2 ;;
        --task) tid=${2:?--task needs a task id}; shift 2 ;;
        --perm) PERM=${2:?--perm needs a mode}; shift 2 ;;
        --mcp) mcps=${2:?--mcp needs a,b or none}; shift 2 ;;
        --allow) ALLOW=${2:?--allow needs a list}; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    guard_outside
    [[ $PERM =~ ^[A-Za-z]*$ ]] || die "bad --perm: $PERM"
    [[ $PERM != plan ]] || ALLOW="Read,Grep,Glob${ALLOW:+,$ALLOW}" # a planner must read without prompts
    [[ -z $tid ]] || has_task "$tid"
    [[ ${id,,} != droverstatusui ]] || die "droverstatusui is reserved for the web user"
    [[ $id != drover ]] || die "drover is reserved"
    valid_id "$id" "agent id"
    [[ -z $(agent "$id" pane_id) ]] || die "agent exists: $id"
    if [[ -n $story ]]; then
      has_story "$story"
      [[ $id == "$story"-* ]] || die "story agent ids are <sid>-<role>, e.g. $story-$id"
    fi
    if ! trusted "$cwd" && [[ $trust != --trust ]]; then
      echo "UNTRUSTED $cwd — ask the user, then run again with --trust" >&2; exit 3
    fi
    rm -f "$ROOT/$HID/agents/$id.mcp.json"
    mcpcfg=''
    if [[ -n $mcps ]]; then # validated before anything is written: an unknown server exits 2
      mcpcfg=$(mcp_config "$cwd" "$mcps") || exit 2
      for m in $(jq -r '.mcpServers | keys[]' <<< "$mcpcfg"); do
        [[ ,${ALLOW// /}, == *,mcp__$m,* ]] || ALLOW="${ALLOW:+$ALLOW,}mcp__$m"
      done
    fi
    write_files "$id" "$purpose" "$story"
    [[ -z $mcps ]] || (umask 077; printf '%s\n' "$mcpcfg" > "$ROOT/$HID/agents/$id.mcp.json") # the file holds server secrets
    [[ -z $tid ]] || task="$task $(task_text "$tid" "$id")"
    csid=$(cat /proc/sys/kernel/random/uuid)
    read -r tab pane < <(launch "$id" "$where" "$cwd" "$model" -- --session-id "$csid" -- "$task")
    # shellcheck disable=SC2015,SC2016
    jset --arg a "$id" --arg p "$purpose" --arg m "$model" --argjson t "$tab" --arg pn "$pane" \
      --arg c "$csid" --arg d "$cwd" --arg tn "$( [[ $where == tab ]] && echo "$id" || agent "${where#pane:}" tab_name)" --arg s "$story" --arg pm "$PERM" --arg al "$ALLOW" --arg mc "$mcps" \
      '.agents[$a] = {purpose: $p, model: $m, tab_id: $t, tab_name: $tn, pane_id: $pn, claude_session_id: $c, cwd: $d, worktree: null, created: (now | todate)}
        + if $s == "" then {} else {story: $s} end + if $pm == "" then {} else {perm: $pm} end + if $al == "" then {} else {allow: $al} end + if $mc == "" then {} else {mcp: $mc} end'
    if [[ $trust == --trust ]] && ! trusted "$cwd"; then
      sleep 4
      z send-keys -p "$pane" Down Enter
      echo "trust answered — verify: zellij -s $(sess) action dump-screen -p $pane"
    fi
    [[ -z $tid ]] || task_mark "$tid" "$id"
    echo "$id $pane (tab $tab, $model)"
    banner
    [[ -n ${DROVER_AGENT:-} ]] || inbox_hint
    ;;
  dispatch) # dispatch <hid> <task-id> [agent] [--fresh] — give an idle agent its task (owner defaults to the task's owner); --fresh: /clear its context first (new phase)
    HID=$1 tid=${2:?task id} fresh=0 id=
    shift 2
    for a in "$@"; do
      if [[ $a == --fresh ]]; then fresh=1; else id=$a; fi
    done
    guard_outside
    has_task "$tid"
    id=${id:-$(jq -r --arg i "$tid" '.[] | select(.id == $i) | .owner // empty' "$ROOT/$HID/tasks.json")}
    [[ -n $id && -n $(agent "$id" pane_id) ]] || die "no agent to dispatch to (pass one: dispatch $HID $tid <agent>)"
    [[ $(state "$id") == idle ]] || die "$id is not idle (state: $(state "$id"))"
    if ((fresh)); then
      type_in "$(agent "$id" pane_id)" "/clear" || die "/clear not delivered to $id"
      sleep 2
      wait_idle "$id"
    fi
    send "$id" drover "$(task_text "$tid" "$id")"
    task_mark "$tid" "$id"
    echo "$tid -> $id"
    ;;
  send) # send <hid> <to> <from> <message>
    HID=$1
    (($# >= 4)) && [[ -n $(trim "${*:4}") ]] || die "usage: drover.sh send <HID> <to> <from> <message> — drover.sh help send"
    [[ $3 == drover || $3 == droverstatusui ]] || valid_id "$3" from
    send "$2" "$3" "${*:4}"
    close_show
    ;;
  report) # report <hid> <agent-id> <task-id> <done|blocked|failed|question> <summary|question> [--changed X] [--open Y] [--options "a|b"] — agents
    HID=$1 id=$2 tid=$3 st=$4 sum=$5 changed=- open=- opts=
    shift 5
    while (($#)); do
      case $1 in
        --changed) changed=${2:?--changed needs a value}; shift 2 ;;
        --open) open=${2:?--open needs a value}; shift 2 ;;
        --options) opts=${2:?--options needs a value}; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ $st =~ ^(done|blocked|failed|question)$ ]] || die "status must be done|blocked|failed|question"
    [[ -z $opts || $st == question ]] || die "--options only with question"
    owner=$(jq -r --arg i "$tid" '.[] | select(.id == $i) | .owner // empty' "$ROOT/$HID/tasks.json" 2> /dev/null || true)
    [[ -n $(agent "$id" pane_id) ]] || die "unknown agent id: $id${owner:+ (task $tid is owned by $owner: report $HID $owner $tid ...)}; agents: $(jq -r '.agents | keys | join(" ")' "$(reg)")"
    [[ -z $owner || $owner == "$id" ]] || die "task $tid is owned by $owner, not $id: report $HID $owner $tid ..."
    known=true
    jq -e --arg i "$tid" 'any(.[]; .id == $i)' "$ROOT/$HID/tasks.json" > /dev/null 2>&1 || known=false
    sum=${sum//[$'\n\r']/ } changed=${changed//[$'\n\r']/ } open=${open//[$'\n\r']/ } opts=${opts//[$'\n\r']/ }
    r="$ROOT/$HID/reports"
    now=$(date -u +%FT%TZ)
    # the agent's own detail survives; a previous one-liner is replaced
    if [[ ! -s $r/$id.$tid.md ]] || { [[ $(wc -l < "$r/$id.$tid.md") -le 1 ]] && [[ $(head -c 6 "$r/$id.$tid.md") == "task: " ]]; }; then
      printf 'task: %s | status: %s | changed: %s | summary: %s | open: %s\n' "$tid" "$st" "$changed" "$sum" "$open" > "$r/$id.$tid.md"
    fi
    # shellcheck disable=SC2016
    jq -nc --arg t "$tid" --arg s "$st" --arg m "$sum" --arg c "$changed" --arg o "$open" --arg at "$now" \
      '{task: $t, status: $s, summary: $m, changed: $c, open: $o, at: $at}' | tee "$r/$id.json" >> "$r/$id.log"
    docs_sync "$id" "${sum:0:140}" "$([[ $changed == - ]] || echo "$changed")" || echo "docs: sync failed" >&2
    # shellcheck disable=SC2016
    ! $known || tset --arg i "$tid" --arg at "$now" --arg s "$st" \
      '(.[] | select(.id == $i)) |= (if $s == "blocked" or $s == "question" then . else .state = $s | .finished_at = $at end)'
    if [[ $st == question ]]; then # waits for `answer`; the story shows waiting-for-user meanwhile
      qs="$ROOT/$HID/questions.json"
      qstory=$(jq -r --arg i "$tid" '.[] | select(.id == $i) | .story // empty' "$ROOT/$HID/tasks.json" 2> /dev/null || true)
      qstory=${qstory:-$(agent "$id" story)}
      [[ -f $qs ]] || echo '[]' > "$qs"
      # shellcheck disable=SC2016
      jfile "$qs" --arg a "$id" --arg t "$tid" --arg q "$sum" --arg o "$opts" --arg at "$now" \
        --arg s "$qstory" \
        'map(select(.agent != $a)) + [{agent: $a, task: $t, text: $q, options: $o, story: $s, at: $at}]'
      notify "drover: $id question" "$tid ${sum:0:100}"
      send drover "$id" "question: $tid ${sum:0:300}${opts:+ [options: $opts]} — answer: drover.sh answer $HID $id \"<answer>\""
    else
      send drover "$id" "report: $tid $st$($known || echo ' (unknown task)')${sum:+ — ${sum:0:140}}"
    fi
    story_derive > /dev/null
    echo "reported: $tid $st"
    ;;
  task) # task <hid> add <id> "<title>" [owner=O] [depends=a,b] [accept="x;y"] [story=S] [kind=K] | set <task-id> key=value... attempts+ | next
    HID=$1 t="$ROOT/$HID/tasks.json"
    case ${2:-} in
      next) # not done, not running, all deps done
        jq -r '[.[] | select(.state == "done") | .id] as $d | .[]
          | select(.state != "done" and .state != "in_progress" and ((.state == "failed" and (.attempts // 0) >= 3) | not) and all(.depends_on[]?; IN($d[])))
          | "\(.id)\t\(.owner // "-")\t\(.title)"' "$t"
        ;;
      list) # list [state]
        jq -r --arg s "${3:-}" '.[] | select($s == "" or .state == $s) | "\(.id)\t\(.state)\t\(.owner // "-")\t\(.title)\t\((.acceptance // []) | join("; ") | if . == "" then "-" else . end)"' "$t" | column -t -s $'\t'
        ;;
      add)
        guard_outside
        tid=${3:?task id} title=$(trim "${4:?title}")
        shift 4
        valid_id "$tid" "task id"
        [[ -n $title ]] || die "empty title"
        [[ -f $t ]] || echo '[]' > "$t"
        jq -e --arg i "$tid" 'any(.[]; .id == $i)' "$t" > /dev/null && die "task exists: $tid"
        [[ -z $(agent "$tid" pane_id) ]] || echo "warning: task id $tid equals agent id $tid; reports and messages may be mixed up" >&2
        owner='' dep='' acc='' story='' kind=''
        for kv in "$@"; do
          case $kv in
            owner=*) owner=$(trim "${kv#*=}") ;;
            depends=*) dep=$(trim "${kv#*=}") ;;
            accept=*) acc=$(trim "${kv#*=}") ;;
            story=*) story=$(trim "${kv#*=}") ;;
            kind=*) kind=$(trim "${kv#*=}") ;;
            *) die "expected owner=O depends=a,b accept=\"x;y\" story=S kind=plan|impl|review|pr: $kv" ;;
          esac
        done
        [[ -z $owner || $owner == drover ]] || valid_id "$owner" owner
        dep=${dep// /}
        IFS=, read -ra deps <<< "$dep"
        for d in "${deps[@]}"; do
          jq -e --arg i "$d" 'any(.[]; .id == $i)' "$t" > /dev/null || die "unknown dependency: $d"
        done
        [[ -z $kind || $kind =~ ^(plan|impl|review|pr)$ ]] || die "kind must be plan|impl|review|pr"
        [[ -n $story || -z $owner ]] || story=$(agent "$owner" story) # a story agent's tasks belong to its story
        [[ -z $story ]] || has_story "$story"
        # shellcheck disable=SC2016
        tset --arg i "$tid" --arg ti "$title" --arg o "$owner" --arg d "$dep" --arg a "$acc" --arg s "$story" --arg k "$kind" \
          '. + [{id: $i, title: $ti, acceptance: ($a | split(";") | map(select(. != ""))), depends_on: ($d | split(",") | map(select(. != ""))),
            owner: (if $o == "" then null else $o end), state: "todo", attempts: 0, created_at: (now | todate)}
            + (if $s == "" then {} else {story: $s} end) + (if $k == "" then {} else {kind: $k} end)]'
        story_derive > /dev/null
        echo "$tid todo${story:+ (story $story)}"
        ;;
      set)
        guard_outside
        tid=${3:?task id}
        shift 3
        has_task "$tid"
        sets='{}' inc=false
        for kv in "$@"; do
          case $kv in
            attempts+) inc=true ;;
            *=*)
              v=$(trim "${kv#*=}")
              [[ ${kv%%=*} != state || $v =~ ^(todo|in_progress|done|failed)$ ]] || die "state must be todo|in_progress|done|failed: $v"
              if [[ ${kv%%=*} == owner && -n $v && $v != drover ]]; then valid_id "$v" owner; fi
              sets=$(jq -c --arg k "${kv%%=*}" --arg v "$v" '. + {($k): $v}' <<< "$sets") ;;
            *) die "expected key=value or attempts+: $kv" ;;
          esac
        done
        # shellcheck disable=SC2016
        tset --arg i "$tid" --argjson s "$sets" --argjson inc "$inc" \
          '(.[] | select(.id == $i)) |= (. + $s | if $s.state == "in_progress" and (.started_at | not) then .started_at = (now | todate) else . end
            | if $s.state == "done" or $s.state == "failed" then .finished_at = (now | todate) else . end | if $inc then .attempts = ((.attempts // 0) + 1) else . end)'
        story_derive > /dev/null
        jq -r --arg i "$tid" '.[] | select(.id == $i) | "\(.id) \(.state) \(.owner // "-") attempts \(.attempts // 0)"' "$t"
        a=$(jq -r --arg i "$tid" '.[] | select(.id == $i) | .attempts // 0' "$t")
        if ((a >= 3)); then
          echo "max attempts: ask the user"
        elif ((a == 2)); then
          echo "hint: suggest the next larger model"
        fi
        ;;
      *) die "task <HID> add <id> \"<title>\" [owner=O] [depends=a,b] [accept=\"x;y\"] | task <HID> set <task-id> key=value... [attempts+] | task <HID> next | task <HID> list [state]" ;;
    esac
    ;;
  answer) # answer <hid> <id> "<answer>" — send the answer to the agent's open question and close it
    HID=$1 id=$2 ans=${3:?answer}
    guard_outside
    qs="$ROOT/$HID/questions.json"
    jq -e --arg a "$id" 'any(.[]?; .agent == $a)' "$qs" > /dev/null 2>&1 || die "no open question from $id"
    q=$(jq -r --arg a "$id" '.[] | select(.agent == $a) | .text' "$qs")
    send "$id" drover "answer to your question \"${q:0:80}\": $ans"
    # shellcheck disable=SC2016
    jfile "$qs" --arg a "$id" 'map(select(.agent != $a))'
    story_derive > /dev/null
    close_show
    echo "answered: $id"
    ;;
  catchup) # catchup <hid> — recent inbox, dashboard, reports newest first
    HID=$1 h="$ROOT/$HID"
    echo "== inbox =="
    [[ ! -s $h/inbox/drover.log ]] || echo "last inbox line: $(($(date +%s) - $(stat -c %Y "$h/inbox/drover.log"))) s ago"
    c=$(wc -l < "$h/inbox/drover.log" 2> /dev/null || echo 0)
    [[ -n ${DROVER_AGENT:-} ]] || echo "$c" > "$h/inbox/offset" # the drover's next `inbox` resumes after these lines
    head -n "$c" "$h/inbox/drover.log" 2> /dev/null | tail -n 20 || true
    echo
    { "$DIR/drover-dashboard.sh" "$HID" || true; } | sed '/^== recent messages ==/,$d' # the inbox tail above covers them
    echo "== reports =="
    # shellcheck disable=SC2012
    ls -lt --time-style=+%H:%M "$h"/reports/*.md 2> /dev/null | awk '{ n = split($7, p, "/"); print $6, p[n] }'
    for f in $(cd "$h/reports" 2> /dev/null && ls -t -- *.json 2> /dev/null); do # shellcheck disable=SC2045
      # shellcheck disable=SC2016
      jq -r --arg a "${f%.json}" '"\($a): \(.task) \(.status) — \(.summary)"' "$h/reports/$f"
    done
    ;;
  pref) # pref [key [value]] — get/set ~/.claude/drover/prefs.json (no key: print all)
    f="$ROOT/prefs.json"
    [[ -f $f ]] || echo '{}' > "$f"
    if [[ -z ${1:-} ]]; then cat "$f"
    elif [[ -z ${2:-} ]]; then jq -r --arg k "$1" '.[$k] // empty' "$f"
    else
      # shellcheck disable=SC2016
      jfile "$f" --arg k "$1" --arg v "$2" '.[$k] = $v'
    fi
    ;;
  inbox) # inbox <hid> — follow new inbox lines (for Monitor)
    HID=$1 f="$ROOT/$1/inbox/drover.log"
    touch "$f"
    pf="$ROOT/$1/inbox/pid"
    if [[ -z ${DROVER_AGENT:-} ]]; then # newest drover watcher wins: also ends orphaned ones (e.g. a Bash run_in_background)
      op=$(cat "$pf" 2> /dev/null || true)
      [[ ! $op =~ ^[0-9]+$ || $op == "$$" ]] || ! tr '\0' ' ' < "/proc/$op/cmdline" 2> /dev/null | grep -q "drover.sh inbox $1" || kill "$op" 2> /dev/null || true
      echo "$$" > "$pf"
    fi
    of="$ROOT/$1/inbox/offset" # lines delivered to the drover's Monitor: catchup sets it, this loop advances it, so a re-armed Monitor loses nothing
    n=''
    [[ -n ${DROVER_AGENT:-} ]] || n=$(cat "$of" 2> /dev/null || true) # agents' Monitors never touch it
    [[ -n $n ]] || n=$(wc -l < "$f")
    exec 4< <(tail -n "+$((n + 1))" -F "$f")
    tp=$!
    # shellcheck disable=SC2064
    trap "kill $tp 2> /dev/null; [[ \$(cat '$pf' 2> /dev/null) != $$ ]] || rm -f '$pf'" EXIT
    while IFS= read -r -u 4 l; do
      k=1
      while ((k < 20)) && IFS= read -r -t 2 -u 4 m; do l+=" ‖ $m"; ((++k)); done # lines within 2 s: one Monitor event, one drover turn
      printf '%s\n' "$l"
      [[ -n ${DROVER_AGENT:-} ]] || { echo $((n += k)) > "$of.$$" && mv "$of.$$" "$of" || true; }
    done
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
  perm) # perm <hid> <id> <mode> — relaunch the agent (--resume) in its tab with another permission mode
    HID=$1 id=$2 PERM=${3:?mode}
    guard_outside
    [[ $PERM =~ ^[A-Za-z]+$ ]] || die "bad mode: $PERM"
    relaunch "$id"
    # shellcheck disable=SC2016
    jset --arg a "$id" --arg pm "$PERM" '.agents[$a].perm = $pm'
    echo "$id -> $PERM"
    banner
    ;;
  purpose) # purpose <hid> <id> "<text>" — change the agent's purpose (system prompt) and relaunch it (--resume)
    HID=$1 id=$2 text=${3:?purpose text}
    guard_outside
    [[ -n $(agent "$id" pane_id) ]] || die "unknown agent: $id"
    # shellcheck disable=SC2016
    jset --arg a "$id" --arg p "$text" '.agents[$a].purpose = $p'
    relaunch "$id"
    echo "$id purpose changed"
    banner
    ;;
  approve) # approve <hid> <task-id> "<scope>" — task-scoped write approval, only after the user's explicit yes to that scope
    HID=$1 tid=${2:?task id} scope=${3:?scope}
    guard_outside
    has_task "$tid"
    id=$(jq -r --arg i "$tid" '.[] | select(.id == $i) | .owner // empty' "$ROOT/$HID/tasks.json")
    [[ -n $id ]] || die "task $tid has no owner"
    # shellcheck disable=SC2016
    tset --arg i "$tid" --arg s "$scope" '(.[] | select(.id == $i)) |= (.approved += [$s])'
    send "$id" drover "approved for task $tid: $scope"
    echo "approved $tid: $scope"
    ;;
  move) # move <hid> <id> <tab|pane:<agent>>
    HID=$1 id=$2 where=$3
    guard_outside
    wait_idle "$id"
    sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
    sid=${sid:-$(agent "$id" claude_session_id)}
    cwd=$(agent "$id" cwd) model=$(agent "$id" model)
    close_agent_pane "$id"
    write_files "$id" "$(agent "$id" purpose)" "$(agent "$id" story)"
    read -r tab pane < <(launch "$id" "$where" "$cwd" "$model" -- --resume "$sid")
    # shellcheck disable=SC2015
    tn=$([[ $where == tab ]] && echo "$id" || agent "${where#pane:}" tab_name)
    # shellcheck disable=SC2016
    jset --arg a "$id" --argjson t "$tab" --arg pn "$pane" --arg c "$sid" --arg tn "$tn" \
      '.agents[$a] += {tab_id: $t, tab_name: $tn, pane_id: $pn, claude_session_id: $c}'
    echo "$id -> $pane (tab $tab)"
    banner
    ;;
  worktree) # worktree <hid> <id> [base] [--branch <name>] [--story <sid>] [--repo <path>] — prints the path to use as spawn cwd | worktree <hid> rm <id>
    HID=$1 id=$2 base='' story='' rm=false bn=''
    shift 2
    if [[ $id == rm ]]; then rm=true id=${1:?agent id}; shift; fi
    while (($#)); do
      case $1 in
        --repo) REPO=$(realpath "${2:?--repo needs a path}"); shift 2 ;;
        --story) story=${2:?--story needs a story id}; shift 2 ;;
        --branch) bn=${2:?--branch needs a name}; shift 2 ;;
        *) base=$1; shift ;;
      esac
    done
    guard_outside
    [[ -z $story ]] || has_story "$story"
    [[ -z $bn ]] || git check-ref-format --branch "$bn" > /dev/null || die "bad branch name: $bn"
    ! $rm || find_repo "$id"
    d=$(wt_dir) || die "project is not a git repo (pass --repo <path>)"
    # shellcheck disable=SC2016
    [[ -z ${REPO:-} ]] || jset --arg r "$REPO" '.repos = ((.repos // []) + [$r] | unique)'
    if $rm; then
      b=$(branch_of "$id")
      git -C "$(repo_root)" worktree remove "$d/$id" || die "not removed (dirty? commit or discard first); the branch $b is kept"
      # shellcheck disable=SC2016
      jset --arg a "$id" 'del(.branches[$a])'
      rmdir "$d" 2> /dev/null || true
      echo "removed $d/$id (branch $b kept)"
      exit 0
    fi
    # shellcheck disable=SC2016
    [[ -z $bn ]] || jset --arg a "$id" --arg b "$bn" '.branches = ((.branches // {}) + {($a): $b})'
    b=$(branch_of "$id")
    mkdir -p "$d"
    if [[ -d $d/$id ]]; then :
    elif git -C "$(repo_root)" show-ref --verify --quiet "refs/heads/$b"; then # reuse the branch
      git -C "$(repo_root)" worktree add "$d/$id" "$b" > /dev/null
    else
      git -C "$(repo_root)" worktree add -b "$b" "$d/$id" "${base:-$(default_base)}" > /dev/null
    fi
    [[ -z $story ]] || "$DIR/drover-story.sh" "$HID" set "$story" branch="$b" worktree="$d/$id" > /dev/null
    echo "$d/$id"
    ;;
  merge) # merge <hid> <id> [--repo <path>] [--yes] — merge the agent's branch into the repo's checked-out branch; needs merge-local in the flow, else --yes after the user's yes
    # shellcheck disable=SC2034
    HID=$1 id=${2:?agent id} YES=0
    shift 2
    while (($#)); do
      case $1 in
        --repo) REPO=$(realpath "${2:?--repo needs a path}"); shift 2 ;;
        --yes) YES=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    guard_outside
    find_repo "$id"
    r=$(repo_root) || die "project is not a git repo (pass --repo <path>)"
    b=$(branch_of "$id")
    flow_gate merge-local "$(agent "$id" story)" "merge $b into $(git -C "$r" branch --show-current)"
    git -C "$r" show-ref --verify --quiet "refs/heads/$b" || die "no branch $b"
    [[ -z $(git -C "$r" status --porcelain --untracked-files=no) ]] || die "$r has uncommitted changes"
    d=$(wt_dir) && [[ ! -d $d/$id || -z $(git -C "$d/$id" status --porcelain) ]] || die "worktree $id has uncommitted changes"
    git -C "$r" merge --no-edit "$b" || { git -C "$r" merge --abort || true; die "merge conflicts: aborted, nothing changed"; }
    echo "merged $b into $(git -C "$r" branch --show-current)"
    ;;
  prlink) # prlink <hid> <id> [--repo <path>] [--yes] — push the agent's branch, print the host's create-PR link (the user opens the PR); needs pr-link or pr in the flow
    # shellcheck disable=SC2034
    HID=$1 id=${2:?agent id} YES=0
    shift 2
    while (($#)); do
      case $1 in
        --repo) REPO=$(realpath "${2:?--repo needs a path}"); shift 2 ;;
        --yes) YES=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    guard_outside
    find_repo "$id"
    r=$(repo_root) || die "project is not a git repo (pass --repo <path>)"
    b=$(branch_of "$id")
    git -C "$r" show-ref --verify --quiet "refs/heads/$b" || die "no branch $b"
    flow_gate "pr-link pr" "$(agent "$id" story)" "push $b and open the PR link"
    git -C "$r" push -u origin "$b" > /dev/null
    base=$(default_base)
    compare_url "$(git -C "$r" remote get-url origin)" "${base#origin/}" "$b"
    ;;
  flow) # flow <hid> [<name>] [tracker=assign,status,comment,link|-] [--story <sid>] — set (name ask clears) or show the effective flow
    HID=$1 name='' trk='' story=''
    shift
    while (($#)); do
      case $1 in
        --story) story=${2:?--story needs a story id}; shift 2 ;;
        tracker=*) trk=${1#*=}; shift ;;
        *) name=$1; shift ;;
      esac
    done
    [[ -z $story ]] || has_story "$story"
    if [[ -n $name$trk ]]; then
      guard_outside
      cur=$(flow_json "$story")
      if [[ $name == ask ]]; then
        f=null
      else
        if [[ -n $name ]]; then f=$(flow_resolve "$name"); else
          [[ -n $cur ]] || die "no flow set: flow $HID <name> [tracker=…]"
          f=$(jq -c 'del(.tracker)' <<< "$cur")
        fi
        t=$(jq -c '.tracker // []' <<< "${cur:-null}")
        if [[ -n $trk ]]; then
          t='[]'
          [[ $trk == - ]] || for x in ${trk//,/ }; do
            [[ $x =~ ^(assign|status|comment|link)$ ]] || die "tracker= takes assign,status,comment,link or -: $x"
            t=$(jq -c --arg x "$x" '. + [$x] | unique' <<< "$t")
          done
        fi
        f=$(jq -c --argjson t "$t" '. + {tracker: $t}' <<< "$f")
      fi
      flow_save "$f" "$story"
      n=0
      for a in $(jq -r '.agents | keys[]' "$(reg)"); do
        s=$(agent "$a" story)
        if [[ -n $story ]]; then [[ $s == "$story" ]] || continue; else [[ -z $s || -z $(flow_story "$s") ]] || continue; fi
        write_files "$a" "$(agent "$a" purpose)" "$s"
        (send "$a" drover "Flow is now $(flow_line "$s")") || echo "not delivered to $a" >&2
        ((++n))
      done
      ((n == 0)) || echo "$n agent(s) told; permissions apply fully after perm/move/revive relaunches them" >&2
    fi
    echo "flow: $(flow_line "$story")"
    ;;
  show) # show <hid> [plan|brief|<path>] — open a document of this corral in a floating pane on the drover tab (the drover never reads it itself)
    HID=$1 p=${2:-plan} h="$ROOT/$1"
    case $p in plan | brief) p=$h/$p.md ;; /*) ;; *) [[ ! -f $h/docs/$p ]] || p=$h/docs/$p ;; esac
    p=$(realpath -m "$p")
    [[ $p == "$h"/* ]] || jq -e --arg p "$p" 'any(.[]?; .path == $p)' "$h/docs.json" > /dev/null 2>&1 || die "not a drover document: $p"
    [[ -f $p ]] || die "no such file: $p"
    pager=(less -R)
    ! command -v bat > /dev/null || pager=(bat --paging=always)
    tab=$(jq -r '.drover.tab_id // empty' "$(reg)")
    close_show
    pane=$(z new-pane --floating --close-on-exit ${tab:+--tab-id "$tab"} --name show -- "${pager[@]}" "$p")
    jset --arg p "$pane" '.drover.show_pane = $p'
    echo "shown $p (q closes)"
    ;;
  repos) # repos <hid> — git roots of the project (and --repo worktrees): branch, submodules
    HID=$1
    { repos; find "$(jq -r .project "$(reg)")" -maxdepth 2 -name .git -printf '%h\n' 2> /dev/null; } | awk 'NF && !seen[$0]++' | while read -r x; do
      [[ $(git -C "$x" rev-parse --show-toplevel 2> /dev/null) == "$x" && -z $(git -C "$x" rev-parse --show-superproject-working-tree 2> /dev/null) ]] || continue
      printf '%s\t%s\n' "$x" "$(git -C "$x" branch --show-current | grep . || echo '(detached)')"
      git -C "$x" submodule status 2> /dev/null | awk '{print $2}' | while read -r m; do
        printf '  %s\t%s\n' "$x/$m" "$(git -C "$x/$m" branch --show-current 2> /dev/null | grep . || echo '(detached)')"
      done
    done | column -t -s $'\t'
    ;;
  worktrees) # worktrees <hid> [--repo <path>] — path, branch, dirty|clean
    HID=$1
    [[ ${2:-} != --repo ]] || REPO=$(realpath "${3:?--repo needs a path}")
    for x in ${REPO:-$(repos)}; do
      d=$(REPO=$x wt_dir) || continue
      [[ -d $d ]] || continue
      for w in "$d"/*/; do
        [[ -d $w ]] || continue
        w=${w%/}
        b=$(git -C "$w" branch --show-current 2> /dev/null)
        [[ -n $(git -C "$w" status --porcelain 2> /dev/null) ]] && st=dirty || st=clean
        echo "$w $b $st"
      done
    done
    ;;
  kill) # kill <hid> <id> [--now [--task todo|failed]] [--reason "<text>"] — refuses a busy/blocked agent or unreported in_progress task unless --now
    HID=$1 id=$2 now=false ts=todo tgiven=false reason=''
    shift 2
    while (($#)); do
      case $1 in
        --now) now=true; shift ;;
        --task) ts=${2:?--task needs todo|failed} tgiven=true; shift 2 ;;
        --reason) reason=${2:?--reason needs a text}; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ $ts =~ ^(todo|failed)$ ]] || die "--task must be todo|failed"
    ! $tgiven || $now || die "--task needs --now"
    guard_outside
    rj="$ROOT/$HID/reports/$id.json"
    # a task counts as reported only by a done/failed report newer than its start
    # shellcheck disable=SC2016
    open=$(jq -r --arg a "$id" --arg r "$(jq -r '.at // empty' "$rj" 2> /dev/null || true)" --arg rt "$(jq -r 'select(.status == "blocked" or .status == "question") | .task' "$rj" 2> /dev/null || true)" \
      '[.[]? | select(.owner == $a and .state == "in_progress" and ($r < (.started_at // "") or .id == $rt)) | .id] | join(" ")' "$ROOT/$HID/tasks.json" 2> /dev/null || true)
    if ! $now; then
      ! [[ $(state "$id") =~ ^(busy|blocked)$ ]] || die "$id is $(state "$id"); wait for it, or kill $HID $id --now after asking the user"
      [[ -z $open ]] || die "$id has in_progress task(s) without a report: $open; wait for the report, or kill $HID $id --now [--task todo|failed] after asking the user"
    elif [[ -n $open ]]; then
      for t in $open; do
        # shellcheck disable=SC2016
        tset --arg i "$t" --arg s "$ts" --arg at "$(date -u +%FT%TZ)" \
          '(.[] | select(.id == $i)) |= (.state = $s | if $s == "failed" then .finished_at = $at else del(.owner, .started_at) end)'
      done
    fi
    close_agent_pane "$id"
    # shellcheck disable=SC2016
    jset --arg a "$id" 'del(.agents[$a], .branches[$a])'
    rm -f "$ROOT/$HID/status/$id.json" "$ROOT/$HID/status/$id.json.lock" "$ROOT/$HID/queue/$id.txt" "$ROOT/$HID/agents/$id.mcp.json"
    # shellcheck disable=SC2016
    [[ ! -f $ROOT/$HID/questions.json ]] || jfile "$ROOT/$HID/questions.json" --arg a "$id" 'map(select(.agent != $a))'
    story_derive > /dev/null
    if [[ -n $reason ]]; then
      reason=${reason//$'\n'/ }
      echo "$(date -Is) [drover-sh] closed $id: $reason" >> "$ROOT/$HID/messages.log"
      echo "[drover-sh -> drover] closed $id: $reason" >> "$ROOT/$HID/inbox/drover.log"
    fi
    echo "closed: $id"
    banner
    ;;
  rename) # rename <hid> <slug>
    HID=$1 slug=$(slugify "${2,,}")
    valid_id "$slug" slug
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
    panes=$(z list-panes -j -t | jq -c '[.[] | "terminal_\(.id)"]')
    while IFS=$'\x1f' read -u 3 -r id pane0 purpose story cwd model csid; do
      ((rc == 1)) || ! jq -e --arg p "$pane0" 'index($p)' <<< "$panes" > /dev/null || continue # a recreated session restarts pane ids
      sid=$(jq -r '.session_id // empty' "$ROOT/$HID/status/$id.json" 2> /dev/null)
      sid=${sid:-$csid}
      write_files "$id" "$purpose" "$story"
      read -r tab pane < <(launch "$id" tab "$cwd" "$model" -- --resume "$sid")
      # shellcheck disable=SC2016
      jset --arg a "$id" --argjson t "$tab" --arg pn "$pane" --arg c "$sid" \
        '.agents[$a] += {tab_id: $t, tab_name: $a, pane_id: $pn, claude_session_id: $c}'
      echo "revived: $id -> $pane"
    done 3< <(jq -r '.agents | to_entries[] | [.key, .value.pane_id, .value.purpose, (.value.story // ""), .value.cwd, .value.model, .value.claude_session_id] | map(. // "") | join("\u001f")' "$(reg)")
    banner
    ;;
  story) # story <hid> <command> ... — story mode, see story.md
    HID=$1
    case ${2:-} in list | show | derive | '') ;; *) guard_outside ;; esac
    exec "$DIR/drover-story.sh" "$@"
    ;;
  status) # status <hid>
    HID=$1
    "$DIR/drover-dashboard.sh" "$HID" "${2:-}" # --all: also done tasks
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
    if jq -e '.remove_worktrees == true' "$(reg)" > /dev/null; then
      for x in $(repos); do
        d=$(REPO=$x wt_dir) && [[ -d $d ]] || continue
        for w in "$d"/*/; do
          [[ -d $w ]] && git -C "$x" worktree remove --force "${w%/}" || true
        done
        git -C "$x" worktree prune || true
        rmdir "$d" "$(dirname "$d")" 2> /dev/null || true
      done
    fi
    for id in $(jq -r '.agents | keys[]' "$(reg)"); do rm -f "$h/status/$id.json" "$h/status/$id.json.lock" "$h/queue/$id.txt"; done
    jset '.closed = true | .shutdown = true | del(.closing_at) | del(.remove_worktrees) | .agents = {}'
    touch "$h/close.done"
    echo "shut down: $s"
    ;;
  doc) # doc <hid> add <path|name> "<note>" [--agent id] | path <name> | rm <name|path> | list — corral documents, kept in <HID>/docs/ and registered in docs.json (brief.md and plan.md are listed automatically)
    HID=$1 dd="$ROOT/$HID/docs" dj="$ROOT/$HID/docs.json"
    mkdir -p "$dd"
    docpath() { # name or abs path -> file in docs/ (a relative name is relative to docs/)
      local n=$1
      [[ $n == /* ]] || n=$dd/$n
      n=$(realpath -m "$n")
      [[ $n == "$dd"/* ]] && echo "$n"
    }
    case ${2:-} in
      add)
        guard_outside
        src=${3:?path or name} note='' agent=''
        shift 3
        [[ ${1:---} == --* ]] || { note=$1; shift; }
        while (($#)); do
          case $1 in
            --agent) agent=${2:?--agent needs an id}; shift 2 ;;
            *) die "unknown option: $1" ;;
          esac
        done
        [[ -z $agent ]] || valid_id "$agent" "agent id"
        if p=$(docpath "$src"); then
          [[ -f $p ]] || die "no such file: $p"
        else # outside docs/: copy it in
          [[ -f $src ]] || die "no such file: $src"
          p=$dd/$(basename "$src")
          [[ ! -e $p ]] || cmp -s "$src" "$p" || die "docs/$(basename "$src") exists with other content: rm it or rename the source"
          cp "$src" "$p"
        fi
        [[ -f $dj ]] || echo '[]' > "$dj"
        # shellcheck disable=SC2016
        jfile "$dj" --arg p "$p" --arg n "$note" --arg a "$agent" \
          'map(select(.path != $p)) + [{path: $p, note: $n, agent: $a, added_at: (now | todate)}]'
        echo "doc: $p"
        ;;
      path) # where an agent should write a new document
        p=$(docpath "${3:?name}") || die "doc name must stay inside $dd: $3"
        mkdir -p "$(dirname "$p")"
        echo "$p"
        ;;
      rm)
        guard_outside
        p=$(docpath "${3:?name or path}") || p=$(realpath -m "$3")
        # shellcheck disable=SC2016
        [[ ! -f $dj ]] || jfile "$dj" --arg p "$p" 'map(select(.path != $p))'
        [[ $p != "$dd"/* ]] || rm -f -- "$p"
        echo "removed: $p"
        ;;
      list | '')
        for p in brief.md plan.md; do
          [[ ! -f $ROOT/$HID/$p ]] || printf '%s\t%s\t%s\n' "$ROOT/$HID/$p" "-" "$p"
        done
        docs_sync # files written to docs/ without a report are registered too
        jq -r '.[]? | "\(.path)\t\(.agent | if . == "" then "-" else . end)\t\(.note)"' "$dj"
        ;;
      *) die "doc <HID> add <path|name> \"<note>\" [--agent id] | path <name> | rm <name|path> | list" ;;
    esac
    ;;
  gc) # gc [days=30] — delete corrals shut down more than <days> ago, trim long message/inbox logs
    for r in "$ROOT"/*/registry.json; do
      [[ -f $r ]] || continue
      h=$(dirname "$r")
      if jq -e '.closed and .shutdown' "$r" > /dev/null 2>&1 && [[ -n $(find "$r" -mtime "+${1:-30}") ]]; then
        rm -rf "$h"
        echo "removed $(basename "$h")"
        continue
      fi
      jq -e '.closed and .shutdown' "$r" > /dev/null 2>&1 || continue # a live or revivable corral's logs are tailed by offset
      for f in "$h/messages.log" "$h/inbox/drover.log"; do
        (($({ wc -l < "$f"; } 2> /dev/null || echo 0) > 2000)) || continue
        tail -n 1000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        rm -f "$h/inbox/offset"
        echo "trimmed $f"
      done
    done
    ;;
  help) # help [cmd] — usage of a command (no cmd: the command list)
    if [[ -n ${1:-} ]]; then
      grep -E "^  ${1//[^a-z_-]/}\) #" "${BASH_SOURCE[0]}" | sed 's/^[^#]*# //' | head -n 1 | grep . || die "no such command: $1"
    else
      echo "commands: new spawn dispatch send report answer repos merge prlink flow show doc gc task story catchup pref inbox help model perm purpose approve move kill worktree worktrees rename flush read revive status close (mutating commands: <cmd> <HID> --force ...)"
    fi
    ;;
  _order) HID=$1; order_tabs ;; # internal: watcher
  _compact) # internal: from the drover's Stop hook — /compact once its context passes DROVER_COMPACT_AT tokens (every turn rereads it)
    HID=$1 pane=$2 h="$ROOT/$1"
    tp=$(jq -r '.transcript_path // empty' "$h/status/drover.json" 2> /dev/null || true)
    [[ -f $tp ]] || exit 0
    [[ ! -f $h/compacted ]] || (($(date +%s) - $(stat -c %Y "$h/compacted") > 600)) || exit 0 # no loop on a stale usage line
    u=$(tac "$tp" | head -n 200 | jq -r 'select(.type == "assistant" and (.isSidechain | not) and .message.usage) | .message.usage
      | .input_tokens + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2> /dev/null | head -n 1 || true)
    ((${u:-0} >= ${DROVER_COMPACT_AT:-120000})) || exit 0
    sleep 3
    [[ $(state drover) == idle ]] || exit 0 # a queued event started the next turn
    type_in "$pane" "/compact Keep: standing user instructions, decisions, open questions and threads, agents and their tasks; the inbox Monitor (Monitor tool, drover.sh inbox) keeps running, do not re-arm it. Drop: tool output, details of finished tasks." 1 1 || exit 0
    touch "$h/compacted"
    ;;
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
      notify "drover: $(sess)" "drover tab gone, run drover.sh revive $HID"
    fi
    ;;
  *) die "commands: new spawn dispatch send report answer repos merge prlink flow show doc gc task story catchup pref inbox model move kill worktree worktrees rename flush read revive status close (mutating commands: <cmd> <HID> --force ...)" ;;
esac
