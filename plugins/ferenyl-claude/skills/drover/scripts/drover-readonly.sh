#!/usr/bin/env bash
# drover-readonly.sh  (PreToolUse hook for plan-mode agents: reads hook JSON from stdin)
# Args: the agent's mcp__ allow entries (--mcp/--allow): every tool of those servers/tools is allowed.
# Other MCP tools are allowed when their name reads as read-only (by verb); anything else falls through to the normal prompt.
set -uo pipefail
write=" set create add update upsert delete remove rm write edit put post patch send push merge install uninstall run exec execute start stop kill close open launch apply move rename index invalidate clear compile deploy commit approve assign cancel import export save toggle switch focus attach pipe broadcast reset restore trigger upload login logout "
read=" get list search find read query fetch resolve lookup describe show view outline inspect status info stats check validate diff explain analyze count browse "
tool=$(jq -r '.tool_name // empty' 2> /dev/null) || exit 0
[[ $tool == mcp__* ]] || exit 0
for a in "$@"; do
  [[ $tool == "$a" || $tool == "$a"__* ]] || continue
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"drover: allowed MCP server in plan mode"}}'
  exit 0
done
tool=${tool##*__}
tokens=$(sed -E 's/([a-z0-9])([A-Z])/\1 \2/g; s/[^A-Za-z0-9]+/ /g' <<< "$tool" | tr '[:upper:]' '[:lower:]')
ok=0
for t in $tokens; do
  [[ $write == *" $t "* ]] && exit 0
  [[ $read == *" $t "* ]] && ok=1
done
((ok)) || exit 0
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"drover: read-only tool in plan mode"}}'
