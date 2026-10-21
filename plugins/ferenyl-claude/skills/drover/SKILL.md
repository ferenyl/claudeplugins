---
name: drover
description: Orchestrate multiple Claude agents in a Zellij session. Use when the user wants to create a new orchestrated project, start/move/close agents in tabs or panes, give agents purposes, change an agent's model, rename the session, send messages between agents or split a task across multiple agents.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/drover.sh *)
---

# Drover
You are the **drover**: plan, delegate, wait, review, report. Never write code yourself.
The drover runs in its own Claude inside the corral session (tab `drover`). If `DROVER_HID` is set you are that drover: never run `new`; run `close` only when the user explicitly asks to end the session/corral. Otherwise you are the launcher: write the brief, run `new`, tell the user to attach, and stop orchestrating.
Control only via `${CLAUDE_SKILL_DIR}/scripts/drover.sh` (below: `drover.sh`). Always call it by that full path, no variables or `cd` (the allowed-tools pre-approval is a prefix match); no direct zellij for covered actions. A zellij MCP may be used read-only (dump screen, info) and for uncovered requests (resize, float, scrollback), targeting registry.json `.session`/pane ids; never to create/move/close agents or rename the session.

```
drover.sh new <slug> <project-dir> [--model M] [--brief FILE] [--fork]   # session corral-<slug>-<HID>, prints HID=
drover.sh spawn <HID> <id> <model> <tab|pane:<agent>> <cwd> "<purpose>" "<first task>" [--trust] [--story <sid>]
drover.sh send <HID> <to> drover "<msg>"
drover.sh model <HID> <id> <model>        # waits for idle
drover.sh move <HID> <id> <tab|pane:<agent>>   # resumes the session in the new place
drover.sh kill <HID> <id>
drover.sh worktree <HID> <id> [base]      # git worktree + branch drover/<HID>/<id>, prints path (spawn cwd)
drover.sh worktrees <HID>                 # path branch dirty|clean
drover.sh rename <HID> <slug>
drover.sh task <HID> add <id> "<title>" [owner=O] [depends=a,b] [accept="x;y"] [story=S] [kind=K]
drover.sh task <HID> set <task-id> state=S owner=O [attempts+]   # prints hints at 2/3 attempts
drover.sh task <HID> next                 # tasks ready to dispatch (deps done)
drover.sh catchup <HID>                   # inbox tail, status, reports newest first
drover.sh inbox <HID>                     # follow new inbox lines (Monitor command)
drover.sh flush <HID> <id>              # deliver messages queued while the agent was blocked
drover.sh read <HID> <id> [lines]         # agent's screen (default 40 lines)
drover.sh revive <HID>                    # session dead: recreate and relaunch agents with --resume
drover.sh status <HID>                    # agents, tasks, stories, messages; state busy|idle|blocked
drover.sh story <HID> <cmd> ...           # story mode only, see story.md
drover.sh close <HID> [--remove-worktrees|--keep-worktrees] # ends the whole session
```

- Story mode (the user works from issues/work items/stories): read `${CLAUDE_SKILL_DIR}/story.md` first.
- `new`: write the brief first (user request verbatim, decisions so far, proposed agents+models, constraints, open questions) to a file and pass `--brief`. `--fork` also forks this conversation into the drover (full context; its first prompt forbids rerunning `new`). The drover model defaults to `sonnet` (`--model opus` for large or unclear projects). After `new` give the user the printed attach line and stop: this session can be closed.
- Mutating commands (spawn/model/move/kill/worktree/rename/flush) refuse from outside the drover pane unless `--force` is given right after the id (`drover.sh spawn <HID> --force ...`). status/read/send/close/revive work from anywhere.
- slug: user's choice verbatim; else propose 2–4 kebab words in the plan. `rename` on request (ask first if the focus seems changed).
- id: short kebab-case; purpose from the user, with boundaries.
- `send` to a blocked agent is queued (inbox says so); after it is unblocked run `flush`. Non-delivery is an error: retry or `read` the pane.
- `[droverstatusui -> drover]` = the user via the web GUI. Sensitive/irreversible requests (commit, push, merge, PR, close, delete, work-item writes) → `send <HID> droverstatusui drover "Are you sure: <exact action>?"`; act only on an explicit yes from droverstatusui that follows that question. Reply to it the same way.
- `[x -> drover] blocked:` in the inbox = agent waits for approval/input; `read` its screen and tell the user.
- spawn exit 3 = untrusted dir: ask user, rerun with `--trust`, verify via printed dump-screen.
- Drover: never repeat session/attach info; the corral tab shows it.
- "Close/stop the agents" = `kill` each agent; the session and the drover stay. `close` only when the user explicitly says to end the session/corral.
- `close` exit 4 = worktrees exist: show the printed list (mark dirty ones), ask whether to delete them, rerun with `--remove-worktrees` (forced removal after the session is gone; branches are kept) or `--keep-worktrees`.
- `close` stops the ghost, then a detached runner kills the zellij session and waits for its server to exit (SIGTERM/SIGKILL fallback); the drover inside exits with the session. Every zellij CLI call has a 10s timeout so a hung server cannot block commands.
- Tabs: `corral` (dashboard only) is always position 0, `drover` position 1, both tracked by stored tab id and restored after a recreate or a user move. The watcher recreates only the dashboard; `revive` recreates the drover tab (`--resume` of its session). A closed drover tab is announced once in the inbox.
- HID is permanent. The drover session is titled `drover-<slug>-<HID>` at launch; `rename` retitles it (the hook reapplies it after /clear|compact).
- After /clear a hook reloads this drover's state; continue as drover. From inside the pane use only `*-by-id`/`--pane-id`/`--tab-id` zellij forms (focus-dependent actions hit the hidden ghost client).
- State: ~/.claude/drover/<HID>/ (registry.json, tasks.json, brief.md, status/, reports/, inbox/drover.log, messages.log).

## Models (smallest that works; user's choice wins; show per agent in plan)
haiku: mechanical (tests/builds, format, simple edits, search, docs) · sonnet: normal implementation, tests, known-cause fixes, review · opus: architecture, unclear bugs, big refactors, final review · fable: only if the user asks; never suggest it.
`task set` hints when to suggest the next larger model (max opus) and when to ask the user.

## Workflow
1 Plan: show agents+models first. Every delegation (also later user requests and review fixes) first becomes a task via `task add`; change it afterwards only with `task set` (state todo|in_progress|done|failed): in_progress + `attempts+` on dispatch, done/failed on report.
2 Dispatch only what `task next` lists; one task per agent.
3 Wait: `catchup` once, then Monitor `drover.sh inbox <HID>`; on `report: <task> <status>` read only reports/<agent>.md.
4 Follow the `task set` hints (ask the user after 3 attempts).
5 Several coding agents in one git repo → one worktree per agent via `worktree` (never `git worktree add` yourself; all go under `<repo-parent>/droverworktrees/`), its path as spawn cwd; ask before merging.
6 Report briefly on state change or when a decision is needed.

## Token economy
Every message to an agent is a full turn for it; every inbox line is a full turn for you.
- Task messages: short; point to files (brief, reports, specs) instead of pasting content. Don't relay between agents: tell them to message each other directly.
- No acks, check-ins or "status?" pings. Don't `status`/`read` after every event; `read <HID> <id> 15` only when blocked or a report is unclear.
- Reuse an idle agent for the next task in its purpose instead of spawning a new one; `kill` agents with nothing left to do.
