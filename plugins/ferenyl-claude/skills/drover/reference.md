# Drover command reference

```
drover.sh new <slug> <project-dir> [--brief FILE] [--fork]   # session corral-<slug>-<HID>, prints HID=
drover.sh spawn <HID> <id> <model> <tab|pane:<agent>> <cwd> "<purpose>" "<first task>" [--trust] [--story <sid>] [--task <tid>] [--perm auto|acceptEdits|plan|...] [--mcp a,b|none] [--allow "Bash(git status *),Bash(git diff *),…"]
drover.sh dispatch <HID> <tid> [agent]    # idle agent gets the task (owner, in_progress, attempts+, id + acceptance sent)
drover.sh send <HID> <to> drover "<msg>"   # exit 3 + inbox note if the target's input box holds text (user typing): retry later
drover.sh answer <HID> <id> "<answer>"    # answers an agent's open `question:` (agents: report <HID> <id> <tid> question "<text>" [--options "a|b"])
drover.sh model <HID> <id> <model>        # waits for idle
drover.sh perm <HID> <id> <mode>          # waits for idle, relaunches it (--resume, same tab) in auto|acceptEdits|plan|default
drover.sh move <HID> <id> <tab|pane:<agent>>   # resumes the session in the new place
drover.sh kill <HID> <id> [--now [--task todo|failed]] [--reason "<text>"]  # refuses busy/blocked or unreported in_progress; ask the user before --now; reason goes to messages.log + inbox  ·  rename <HID> <slug>  ·  flush <HID> <id> (deliver messages queued while blocked)
drover.sh worktree <HID> <id> [base] [--branch <name>] [--repo <path>] [--story <sid>] | rm <id>   # branch default drover/<HID>/<id>, base default origin/HEAD; prints path (spawn cwd); rm keeps the branch
drover.sh worktrees <HID> [--repo <path>] # path branch dirty|clean
drover.sh repos <HID>                     # git roots of the project, current branch, submodules
drover.sh merge <HID> <id> [--repo <path>] [--yes]  # branch into the checked-out branch; needs merge-local in the flow, else --yes after the user's yes (exit 6 = not in flow)
drover.sh prlink <HID> <id> [--repo <path>] [--yes]  # push the agent's branch, print the create-PR link (pr-link|pr)
drover.sh flow <HID> [<name>|ask] [tracker=assign,status,comment,link|-] [--story <sid>]   # set/show the git/PR flow (corral, or one story)
drover.sh show <HID> [plan|brief|<path>]  # open a corral document in a floating pane on the drover tab (q closes; send/answer close it too)
drover.sh task <HID> add <id> "<title>" [owner=O] [depends=a,b] [accept="x;y"]   # + story=S kind=K: story.md
drover.sh task <HID> set <task-id> state=S owner=O [attempts+]   # prints hints at 2/3 attempts
drover.sh task <HID> next | list [state]  # ready to dispatch (deps done) | all, with acceptance
drover.sh doc <HID> add <abs-path> "<note>" [--agent id] | rm <path> | list   # docs for the user (brief.md, plan.md automatic)
drover.sh catchup <HID>                   # inbox tail + age of the last inbox line, status, reports (summaries) newest first
drover.sh inbox <HID>                     # follow new inbox lines (Monitor command)
drover.sh read <HID> <id> [lines]         # agent's screen (default 40 lines)
drover.sh revive <HID>                    # session dead: recreate and relaunch agents with --resume
drover.sh status <HID> [--all]            # agents, tasks (done hidden unless --all), stories, messages
drover.sh story <HID> <cmd> ...           # story mode only, see story.md
drover.sh close <HID> [--remove-worktrees|--keep-worktrees] # ends the whole session  ·  gc [days=30]: delete old shut-down corrals
drover.sh pref [key [value]]        # get/set ~/.claude/drover/prefs.json (e.g. perm, flow)
```
