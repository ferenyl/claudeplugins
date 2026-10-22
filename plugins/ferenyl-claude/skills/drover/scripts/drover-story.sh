#!/usr/bin/env bash
# drover-story.sh <HID> <command> ... — story mode, called via drover.sh story; see ../story.md
# Tracker writes are only `assign` and `comment` (the drover asks the user first); statuses are never written back.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
HID=${1:?HID} cmd=${2:-}
shift 2 || true
h="$HOME/.claude/drover/$HID" S="$HOME/.claude/drover/$HID/stories.json"
[[ -f $h/registry.json ]] || die "unknown drover: $HID"
[[ -f $h/tasks.json ]] || echo '[]' > "$h/tasks.json" # derive/list/show read it before the first task add
az() { # azure_config (story mode): another folder's az login
  local d
  d=$(jq -r '.story_mode.azure_config // empty' "$h/registry.json")
  if [[ -n $d ]]; then AZURE_CONFIG_DIR=$d command az "$@"; else command az "$@"; fi
}
STATUSES="backlog planning working waiting-for-user review done"

sset() { jfile "$S" "$@"; }
now() { date -u +%FT%TZ; }
init() { [[ -f $S ]] || echo '[]' > "$S"; mkdir -p "$h/stories"; }
story() { jq -r --arg i "$1" ".[] | select(.id == \$i) | .$2 // empty" "$S"; }
need() { jq -e --arg i "$1" 'any(.[]; .id == $i)' "$S" > /dev/null 2>&1 || die "unknown story: $1"; }
mcp() { # what failed, what to do instead: exit 5 = use the tracker MCP
  if [[ $1 == az\ * ]]; then
    echo "$1 failed (not logged in?): first find an az config dir (CLAUDE.md, else ask the user) and run 'story mode azure_config=DIR', then retry; only if that fails use the tracker MCP, then $2" >&2
  else
    echo "$1 failed (CLI missing or not authenticated?): use the tracker MCP instead, then $2" >&2
  fi
  exit 5
}
yn() { case $1 in y | yes | true | 1) echo true ;; n | no | false | 0) echo false ;; *) die "expected y|n: $1" ;; esac; }
project() { jq -r .project "$h/registry.json"; }
remote() { git -C "${1:-$(project)}" remote get-url origin 2> /dev/null || true; }
gh_repo() { # remote url -> owner/repo, empty if not github
  [[ $1 =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 0
  echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
}
az_org() { echo "https://dev.azure.com/${1%%/*}"; } # source org/project -> org url

write_md() { # id title url body: the file agents read; keeps earlier clarifications
  local f="$h/stories/$1.md" c=
  [[ ! -f $f ]] || c=$(sed -n '/^## Clarification (/,$p' "$f")
  {
    printf '# %s\n\n' "$2"
    [[ -z $3 ]] || printf '%s\n\n' "$3"
    [[ -z $4 ]] || printf '%s\n' "$4"
    [[ -z $c ]] || printf '\n%s\n' "$c"
  } > "$f"
}

store() { # item json {id,key,tracker,source,type,title,url,body,assignee,tracker_state}: insert, or refresh tracker fields (status, branch, pr… kept)
  local n=$1 id
  [[ -z $sid ]] || n=$(jq -c --arg i "$sid" '.id = $i' <<< "$n")
  id=$(jq -r .id <<< "$n")
  [[ $id =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "story id must be kebab-case: $id (pass id=)"
  init
  ! jq -e --argjson n "$n" 'any(.[]; .id == $n.id and (.tracker != $n.tracker or .key != $n.key))' "$S" > /dev/null ||
    die "story id $id is taken by another item: pass id=<other>"
  write_md "$id" "$(jq -r .title <<< "$n")" "$(jq -r '.url // empty' <<< "$n")" "$(jq -r '.body // ""' <<< "$n")"
  # shellcheck disable=SC2016
  sset --argjson n "$(jq -c '((.body // "") | gsub("\\s+"; " ") | .[0:300]) as $s | del(.body) + {summary: $s}' <<< "$n")" --arg t "$(now)" '
    if any(.[]; .id == $n.id) then map(if .id == $n.id then . + $n + {fetched_at: $t, updated_at: $t} else . end)
    else . + [{id: $n.id, status: "backlog", status_manual: false, blocked: null, order: (([.[].order // 0] | max // 0) + 1),
      branch: null, worktree: null, pr: null, clarified: false, file: "stories/\($n.id).md", fetched_at: $t, updated_at: $t} + $n] end'
  echo "$id $(jq -r .title <<< "$n")"
}

gh_fetch() { # number owner/repo
  local j
  j=$(gh issue view "$1" -R "$2" --json number,title,body,url,state,assignees) || mcp "gh issue view $1" "story add"
  # shellcheck disable=SC2016
  store "$(jq -c --arg s "$2" '{id: (.number | tostring), key: (.number | tostring), tracker: "github", source: $s, type: "issue",
    title, url, body, assignee: (.assignees[0].login // null), tracker_state: .state}' <<< "$j")"
}

az_fetch() { # id [org-url]
  local j
  j=$(az boards work-item show --id "$1" ${2:+--org "$2"} -o json) || mcp "az boards work-item show $1" "story add"
  store "$(jq -c 'def txt: (. // "") | gsub("<br ?/?>|</p>|</div>|</li>"; "\n") | gsub("<[^>]+>"; "") | gsub("&nbsp;"; " ")
      | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&amp;"; "&");
    .fields as $f | (.url | capture("//(dev\\.azure\\.com/)?(?<o>[^/.]+)") .o) as $o | $f["System.TeamProject"] as $p
    | {id: (.id | tostring), key: (.id | tostring), tracker: "azure", source: "\($o)/\($p)", type: $f["System.WorkItemType"],
      title: $f["System.Title"], url: "https://dev.azure.com/\($o)/\($p | @uri)/_workitems/edit/\(.id)",
      body: ([($f["System.Description"] | txt),
        ($f["Microsoft.VSTS.TCM.ReproSteps"] // empty | "## Repro steps\n" + txt),
        ($f["Microsoft.VSTS.Common.AcceptanceCriteria"] // empty | "## Acceptance criteria\n" + txt)] | join("\n\n")),
      assignee: ($f["System.AssignedTo"].displayName // null), tracker_state: $f["System.State"]}' <<< "$j")"
}

jira_fetch() { # KEY
  local j
  j=$(jira issue view "$1" --raw) || mcp "jira issue view $1" "story add"
  store "$(jq -c '.fields as $f | (.self | capture("//(?<h>[^/]+)").h) as $host
    | {id: (.key | ascii_downcase), key, tracker: "jira", source: $host, type: ($f.issuetype.name // null), title: $f.summary,
      url: "https://\($host)/browse/\(.key)", assignee: ($f.assignee.displayName // null), tracker_state: ($f.status.name // null),
      body: ($f.description // "" | if type == "string" then . else
        [.content[]? | [.. | objects | select(.type == "text") | .text] | join("")] | join("\n\n") end)}' <<< "$j")"
}

guess_tracker() { # tracker for bare numbers/queries: tracker= > repo= > project remote
  local r
  [[ -z $tracker ]] || { echo "$tracker"; return; }
  [[ -z $repo ]] || { echo github; return; }
  r=$(remote)
  if [[ -n $(gh_repo "$r") ]]; then echo github
  elif [[ $r == *dev.azure.com* || $r == *visualstudio.com* ]]; then echo azure
  else die "cannot tell the tracker: pass repo=owner/repo or tracker=azure|jira"
  fi
}

derive() { # auto status of every story without status_manual (contract table, first match wins)
  [[ -f $S ]] || return 0
  local n bl=()
  for n in $(jq -r '.agents | keys[]' "$h/registry.json"); do # registry agents only: a killed agent's leftover status must not pin its story
    if [[ $(jq -r .state "$h/status/$n.json" 2> /dev/null) == blocked ]]; then bl+=("$n"); fi
  done
  # shellcheck disable=SC2016
  sset --slurpfile t "$h/tasks.json" --slurpfile r "$h/registry.json" --arg now "$(now)" \
    --argjson b "$(printf '%s\n' "${bl[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson q "$(jq -c '[.[]?.story]' "$h/questions.json" 2> /dev/null || echo '[]')" '
    ($t[0] // []) as $tasks | ($r[0].agents // {}) as $ag
    | map(if .status_manual then . else
      .id as $i | [$tasks[] | select(.story == $i)] as $st
      | [$st[] | select((.kind // "impl") != "plan")] as $impl | [$st[] | select(.kind == "plan")] as $plan
      | ([$ag | to_entries[] | select(.value.story == $i) | .key] + [$st[] | select(.state == "in_progress") | .owner // empty]) as $who
      | (if .pr.state == "merged" and all($st[]; .state == "done") then "done"
        elif .pr.state == "draft" or .pr.state == "open" or (($impl | length) > 0 and all($st[]; .state == "done") and .pr == null) then "review"
        elif any($who[]; IN($b[])) or ($i | IN($q[])) or any($st[]; .state == "failed" and (.attempts // 0) >= 3) then "waiting-for-user"
        elif any($impl[]; .state != "todo") then "working"
        elif any($plan[]; .state != "todo") then "planning"
        else "backlog" end) as $s
      | if $s != .status then .status = $s | .updated_at = $now else . end end)'
}

list() {
  [[ -f $S ]] || { echo "no stories"; return 0; }
  jq -r 'def yn: if . == null then "-" elif . then "y" else "n" end;
    .story_mode // empty | "mode: \(if .parallel then "parallel" else "sequential" end) planner=\(.planner | yn) pr=\(.pr | yn) pr_review=\(.pr_review | yn)"' "$h/registry.json"
  # shellcheck disable=SC2016
  jq -r --slurpfile t "$h/tasks.json" '($t[0] // []) as $tasks | sort_by(.order // 0)[]
    | .id as $i | [$tasks[] | select(.story == $i)] as $st
    | "\(.id)\t\(.status)\(if .status_manual then "*" else "" end)\t\([$st[] | select(.state == "done")] | length)/\($st | length)\t\(.pr.url // "-")\(if .pr then " (\(.pr.state)\(if .pr.review then ", \(.pr.review)" else "" end))" else "" end)\t\(.title)\(if .blocked then "  [blocked: \(.blocked)]" else "" end)"' "$S" |
    column -t -s $'\t'
}

pr_ref() { # sid url|number: the pr record of an existing PR (created by an agent via MCP)
  local r j
  r=$(remote "$(story "$1" worktree)")
  [[ -n $r ]] || r=$(remote)
  if [[ $2 =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
    jq -nc --arg u "$2" --argjson n "${BASH_REMATCH[2]}" '{url: $u, number: $n, host: "github", state: "open", review: null}'
  elif [[ $2 =~ /pullrequest/([0-9]+) ]]; then
    jq -nc --arg u "$2" --argjson n "${BASH_REMATCH[1]}" '{url: $u, number: $n, host: "azure", state: "open", review: null}'
  elif [[ $2 =~ ^#?([0-9]+)$ && -n $(gh_repo "$r") ]]; then
    j=$(gh pr view "${BASH_REMATCH[1]}" -R "$(gh_repo "$r")" --json url,number) || die "gh pr view ${BASH_REMATCH[1]} failed"
    jq -c '. + {host: "github", state: "open", review: null}' <<< "$j"
  else
    die "pr=<PR url> (a bare number works for github remotes only): $2"
  fi
}

pr_sync() { # sid: refresh pr state/review from the host
  local u n j v
  u=$(story "$1" pr.url) n=$(story "$1" pr.number)
  [[ -n $u ]] || return 0
  if [[ $(story "$1" pr.host) == github ]]; then
    j=$(gh pr view "$u" --json state,reviewDecision,isDraft) || { echo "gh pr view $u failed" >&2; return 0; }
    v=$(jq -c '{state: (if .state == "MERGED" then "merged" elif .state == "CLOSED" then "closed" elif .isDraft then "draft" else "open" end),
      review: ({APPROVED: "approved", CHANGES_REQUESTED: "changes_requested", REVIEW_REQUIRED: "requested"}[.reviewDecision // ""] // null)}' <<< "$j")
  else
    [[ $u =~ (https://dev\.azure\.com/[^/]+) ]] || [[ $u =~ (https://[^/.]+\.visualstudio\.com) ]] || return 0
    j=$(az repos pr show --id "$n" --org "${BASH_REMATCH[1]}" -o json) || { echo "az repos pr show $n failed" >&2; return 0; }
    v=$(jq -c '[.reviewers[]?.vote] as $v | {state: (if .status == "completed" then "merged" elif .status == "abandoned" then "closed" elif .isDraft then "draft" else "open" end),
      review: (if any($v[]; . == -10) then "changes_requested" elif ($v | length) > 0 and all($v[]; . >= 5) then "approved"
        elif ($v | length) > 0 then "requested" else null end)}' <<< "$j")
  fi
  # shellcheck disable=SC2016
  sset --arg i "$1" --argjson v "$v" --arg t "$(now)" 'map(if .id == $i then .pr += $v | .updated_at = $t else . end)'
}

auto_sync() { # list/show: refresh open PRs at most once per 60 s, so a merge shows without `sync`
  local f=$h/pr_synced i
  [[ -f $S ]] || return 0
  if [[ -f $f ]] && (($(date +%s) - $(stat -c %Y "$f") < 60)); then return 0; fi
  touch "$f"
  for i in $(jq -r '.[] | select(.pr.state == "open" or .pr.state == "draft") | .id' "$S"); do pr_sync "$i"; done
  derive
}

sid=
case $cmd in
  fetch) # fetch <ref...> [repo=o/r] [tracker=github|azure|jira] [org=URL] [query="..."] [id=<sid>]
    refs=() repo='' tracker='' org='' query=''
    for a; do
      case $a in
        repo=*) repo=${a#*=} ;;
        tracker=*) tracker=${a#*=} ;;
        org=*) org=${a#*=} ;;
        query=*) query=${a#*=} ;;
        id=*) sid=${a#*=} ;;
        *) refs+=("$a") ;;
      esac
    done
    ((${#refs[@]} > 0)) || [[ -n $query ]] || die "fetch <ref...> [repo=o/r] [tracker=…] [org=URL] [query=\"…\"] [id=<sid>]"
    [[ -z $sid || ${#refs[@]} == 1 ]] || die "id= needs exactly one ref"
    if [[ -n $query ]]; then
      case $(guess_tracker) in
        github)
          repo=${repo:-$(gh_repo "$(remote)")}
          ns=$(gh issue list -R "$repo" --search "$query" --json number -q '.[].number') || mcp "gh issue list" "story add"
          ;;
        azure)
          ns=$(az boards query --wiql "$query" ${org:+--org "$org"} -o json | jq -r '.[].id') || mcp "az boards query" "story add"
          tracker=azure
          ;;
        jira) ns=$(jira issue list -q "$query" --plain --columns key --no-headers) || mcp "jira issue list" "story add" ;;
        *) die "unknown tracker: $tracker" ;;
      esac
      [[ -z $ns ]] || mapfile -t -O "${#refs[@]}" refs <<< "$ns"
      ((${#refs[@]} > 0)) || { echo "no items match"; exit 0; }
    fi
    for ref in "${refs[@]}"; do
      if [[ $ref =~ github\.com/([^/]+/[^/]+)/issues/([0-9]+) ]]; then
        gh_fetch "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
      elif [[ $ref =~ ^(https://dev\.azure\.com/[^/]+|https://[^/.]+\.visualstudio\.com)/.*[/=]([0-9]+)$ ]]; then
        az_fetch "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
      elif [[ $ref =~ /browse/([A-Za-z][A-Za-z0-9]*-[0-9]+) ]]; then
        jira_fetch "${BASH_REMATCH[1]^^}"
      elif [[ $ref =~ ^#?([0-9]+)$ ]]; then
        n=${BASH_REMATCH[1]}
        case $(guess_tracker) in
          github) gh_fetch "$n" "${repo:-$(gh_repo "$(remote)")}" ;;
          azure) az_fetch "$n" "$org" ;;
          *) die "bare number $n: pass repo=owner/repo or tracker=azure" ;;
        esac
      elif [[ $ref =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]]; then
        jira_fetch "${ref^^}"
      else
        die "unrecognized ref: $ref (issue URL/#N, work item URL/id, JIRA-KEY)"
      fi
    done
    derive
    ;;
  add) # add <sid> "<title>" [tracker=T] [key=K] [url=U] [source=S] [type=T] [assignee=A] [state=S] [file=F] — import (MCP/manual)
    sid=${1:?sid} title=${2:?title}
    shift 2
    n=$(jq -nc --arg i "$sid" --arg t "$title" '{id: $i, key: $i, tracker: "manual", source: null, type: null, title: $t, url: null, assignee: null, tracker_state: null, body: ""}')
    for kv; do
      case $kv in
        file=*) [[ -f ${kv#*=} ]] || die "no such file: ${kv#*=}"; n=$(jq -c --rawfile b "${kv#*=}" '.body = $b' <<< "$n") ;;
        tracker=* | key=* | url=* | source=* | type=* | assignee=*) n=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<< "$n") ;;
        state=*) n=$(jq -c --arg v "${kv#*=}" '.tracker_state = $v' <<< "$n") ;;
        *) die "expected tracker= key= url= source= type= assignee= state= file=: $kv" ;;
      esac
    done
    store "$n"
    derive
    ;;
  mode) # mode parallel|sequential [planner=y|n] [pr=y|n] [pr_review=y|n] [azure_config=DIR|-]
    m='{}'
    for a; do
      case $a in
        parallel | sequential) m=$(jq -c --argjson v "$([[ $a == parallel ]] && echo true || echo false)" '.parallel = $v' <<< "$m") ;;
        planner=* | pr=* | pr_review=*) m=$(jq -c --arg k "${a%%=*}" --argjson v "$(yn "${a#*=}")" '.[$k] = $v' <<< "$m") ;;
        azure_config=*) # AZURE_CONFIG_DIR for every az call of this script (not the agents' own az); - clears
          v=${a#*=} v=${v/#\~/$HOME}
          [[ $v == - || -d $v ]] || die "no such directory: $v"
          [[ $v == - ]] || v=$(realpath "$v")
          m=$(jq -c --arg v "$v" '.azure_config = (if $v == "-" then null else $v end)' <<< "$m") ;;
        *) die "mode parallel|sequential [planner=y|n] [pr=y|n] [pr_review=y|n] [azure_config=DIR|-]" ;;
      esac
    done
    # shellcheck disable=SC2016
    jfile "$h/registry.json" --argjson m "$m" '.story_mode = ((.story_mode // {parallel: false}) + $m)'
    jq -c .story_mode "$h/registry.json"
    ;;
  set) # set <sid> status=S|auto blocked="r"|- order=N clarify="text" branch=B worktree=W assignee=A pr=<url|nr> (- = null)
    sid=${1:?sid}
    shift
    need "$sid"
    sets='{}' clar=false syncpr=false
    for kv; do
      k=${kv%%=*} v=${kv#*=}
      [[ $kv == *=* ]] || die "expected key=value: $kv"
      case $k in
        status)
          if [[ $v == auto ]]; then sets=$(jq -c '.status_manual = false' <<< "$sets")
          else
            [[ " $STATUSES " == *" $v "* ]] || die "status must be auto or one of: $STATUSES"
            sets=$(jq -c --arg v "$v" '.status = $v | .status_manual = true' <<< "$sets")
          fi
          ;;
        order) [[ $v =~ ^[0-9]+$ ]] || die "order must be a number"; sets=$(jq -c --argjson v "$v" '.order = $v' <<< "$sets") ;;
        blocked | branch | worktree | assignee) sets=$(jq -c --arg k "$k" --arg v "$v" '.[$k] = (if $v == "-" then null else $v end)' <<< "$sets") ;;
        pr)
          if [[ $v == - ]]; then sets=$(jq -c '.pr = null' <<< "$sets")
          else
            sets=$(jq -c --argjson p "$(pr_ref "$sid" "$v")" '.pr = $p' <<< "$sets")
            syncpr=true
          fi
          ;;
        clarify)
          printf '\n## Clarification (%s)\n%s\n' "$(date +%F)" "$v" >> "$h/stories/$sid.md"
          clar=true
          ;;
        *) die "unknown key: $k" ;;
      esac
    done
    # shellcheck disable=SC2016
    sset --arg i "$sid" --argjson s "$sets" --argjson c "$clar" --arg t "$(now)" 'map(if .id == $i then . + $s | .updated_at = $t
      | if $c then .clarified = true | (if .status_manual and .status == "waiting-for-user" then .status_manual = false else . end) else . end
      else . end)'
    ! $syncpr || pr_sync "$sid"
    derive
    list | grep -E "^$sid " || true
    ;;
  list) auto_sync; list ;;
  show) # show <sid>: story, its tasks and agents
    sid=${1:?sid}
    need "$sid"
    auto_sync
    jq --arg i "$sid" '.[] | select(.id == $i) | del(.summary)' "$S"
    echo "file: $h/stories/$sid.md"
    echo "tasks:"
    jq -r --arg i "$sid" '.[] | select(.story == $i) | "  \(.id)\t\(.state)\t\(.kind // "impl")\t\(.owner // "-")\t\(.title)"' "$h/tasks.json" | column -t -s $'\t'
    echo "agents:"
    jq -r --arg i "$sid" '.agents | to_entries[] | select(.value.story == $i) | "  \(.key) \(.value.model)"' "$h/registry.json"
    ;;
  derive) derive ;;
  assign) # assign <sid>: set the tracker assignee to the current CLI user (ask the user first)
    sid=${1:?sid}
    need "$sid"
    k=$(story "$sid" key) src=$(story "$sid" source) u=$(story "$sid" url)
    case $(story "$sid" tracker) in
      github)
        gh issue edit "$k" -R "$src" --add-assignee @me > /dev/null || mcp "gh issue edit" "story set $sid assignee=<name>"
        me=$(gh api user -q .login)
        ;;
      azure)
        me=$(az account show --query user.name -o tsv) || mcp "az account show" "story set $sid assignee=<name>"
        az boards work-item update --id "$k" --org "$(az_org "$src")" --assigned-to "$me" -o none || mcp "az boards work-item update" "story set $sid assignee=<name>"
        ;;
      jira)
        me=$(jira me) || mcp "jira me" "story set $sid assignee=<name>"
        jira issue assign "$k" "$me" > /dev/null || mcp "jira issue assign" "story set $sid assignee=<name>"
        ;;
      *) mcp "assign (no tracker CLI for this story)" "assign ${u:-$sid} to the user, story set $sid assignee=<name>" ;;
    esac
    # shellcheck disable=SC2016
    sset --arg i "$sid" --arg a "$me" --arg t "$(now)" 'map(if .id == $i then .assignee = $a | .updated_at = $t else . end)'
    echo "$sid assigned to $me"
    ;;
  comment) # comment <sid> "<text>": clarification comment on the work item (ask the user first)
    sid=${1:?sid} text=${2:?text}
    need "$sid"
    k=$(story "$sid" key) src=$(story "$sid" source) u=$(story "$sid" url)
    case $(story "$sid" tracker) in
      github) gh issue comment "$k" -R "$src" --body "$text" > /dev/null || mcp "gh issue comment" "nothing else" ;;
      azure) az boards work-item update --id "$k" --org "$(az_org "$src")" --discussion "$text" -o none || mcp "az boards work-item update" "nothing else" ;;
      jira) jira issue comment add "$k" "$text" > /dev/null || mcp "jira issue comment add" "nothing else" ;;
      *) mcp "comment (no tracker CLI for this story)" "comment on ${u:-$sid}" ;;
    esac
    echo "commented on $sid"
    ;;
  pr) # pr <sid> [--draft] [--title T] [--body-file F]: push the story branch, create the PR (or record an existing one); title/body per the instructions in effect
    sid=${1:?sid}
    shift
    need "$sid"
    draft='' title='' bodyf=''
    while (($#)); do
      case $1 in
        --draft) draft=1; shift ;;
        --title) title=${2:?--title needs a value}; shift 2 ;;
        --body-file) bodyf=${2:?--body-file needs a file}; shift 2 ;;
        *) die "pr <sid> [--draft] [--title T] [--body-file F]" ;;
      esac
    done
    [[ -z $bodyf || -f $bodyf ]] || die "no such file: $bodyf"
    d=$(story "$sid" worktree)
    d=${d:-$(git -C "$(project)" rev-parse --show-toplevel)}
    b=$(story "$sid" branch)
    b=${b:-$(git -C "$d" branch --show-current)}
    [[ -n $b ]] || die "no branch for $sid: story set $sid branch=B"
    t=${title:-$(story "$sid" title)} r=$(remote "$d")
    git -C "$d" push -u origin "$b"
    if [[ -n $(gh_repo "$r") ]]; then
      gh pr view "$b" -R "$(gh_repo "$r")" > /dev/null 2>&1 ||
        { [[ -n $bodyf ]] || echo "warning: no --body-file: the PR body is empty (PR templates are not applied)" >&2
          gh pr create -R "$(gh_repo "$r")" --head "$b" --title "$t" --body-file "${bodyf:-/dev/null}" ${draft:+"--draft"} > /dev/null; }
      j=$(gh pr view "$b" -R "$(gh_repo "$r")" --json url,number,state,isDraft)
      p=$(jq -c '{url, number, host: "github", state: (if .isDraft then "draft" else (.state | ascii_downcase) end), review: null}' <<< "$j")
    elif [[ $r == *dev.azure.com* || $r == *visualstudio.com* ]]; then
      body=()
      [[ -z $bodyf ]] || body=(--description "$(< "$bodyf")")
      j=$(cd "$d" && az repos pr create --detect true --source-branch "$b" --title "$t" "${body[@]}" --draft "$([[ -n $draft ]] && echo true || echo false)" -o json) || mcp "az repos pr create" "story set $sid pr=<url|nr>"
      p=$(jq -c '{url: "\(.repository.webUrl)/pullrequest/\(.pullRequestId)", number: .pullRequestId, host: "azure",
        state: (if .isDraft then "draft" else "open" end), review: null}' <<< "$j")
    else
      die "PR host not supported for remote: $r"
    fi
    # shellcheck disable=SC2016
    sset --arg i "$sid" --argjson p "$p" --arg b "$b" --arg t "$(now)" 'map(if .id == $i then .pr = $p | .branch = $b | .updated_at = $t else . end)'
    derive
    jq -r .url <<< "$p"
    ;;
  sync) # sync: refresh PR state/review of every story with a PR, re-derive
    [[ -f $S ]] || exit 0
    for i in $(jq -r '.[] | select(.pr != null) | .id' "$S"); do pr_sync "$i"; done
    derive
    list
    ;;
  *) die "story <HID> fetch|add|mode|set|list|show|assign|comment|pr|sync — see story.md" ;;
esac
