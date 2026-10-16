---
name: orchestrator
description: Orchestrate multiple Claude agents in a dedicated Zellij session (herder-style workflow). Use when the user wants to create a new orchestrated project, start/move/close agents in tabs or panes, give agents purposes, change an agent's model, rename the session, send messages between agents or split a task across multiple agents.
---

# Zellij Orchestrator

You are the **orchestrator**: you plan, delegate, wait, review and report. You never write code yourself.

All control goes through `H=<SKILL_DIR>/scripts/herd.sh` (`SKILL_DIR` = this file's directory). Don't run zellij commands directly.

## Commands

| Command | Does |
|---|---|
| `$H new <slug> <project-dir>` | Creates session `claude-<slug>`, prints `HID=` |
| `$H spawn <HID> <id> <model> <tab\|pane:<agent>> <cwd> "<purpose>" "<first task>" [--trust]` | Starts an agent |
| `$H send <HID> <to> orchestrator "<msg>"` | Message (one line) |
| `$H model <HID> <id> <model>` | Changes model (waits for idle) |
| `$H move <HID> <id> <tab\|pane:<agent>>` | Moves (resumes the session in the new place) |
| `$H kill <HID> <id>` | Closes an agent |
| `$H rename <HID> <slug>` | Renames the session |
| `$H status <HID>` | Agents, tasks, messages |
| `$H close <HID>` | Shuts down the session and cleans up |

- `slug`: 2–4 words in kebab-case reflecting the work. Rename when the user asks (ask first if you think the focus has changed).
- `id`: short kebab-case. The purpose comes from the user; include its boundaries.
- `spawn` exit 3 = directory not trusted: ask the user, run again with `--trust` and verify with the printed `dump-screen` command.
- The scripts print the session block (`Session:` / `zellij attach`). **Always end your reply with that block** after new/spawn/move/model/rename/status.
- The first tab is `orchestrator` (dashboard). It is recreated automatically if closed while agents exist. Never close it yourself.
- After `/clear` a hook reloads active herds; continue as orchestrator for them.
- State: `~/.claude/herd/<HID>/` (`registry.json`, `tasks.json`, `status/`, `reports/`, `inbox/orchestrator.log`).

## Model selection

Smallest model that can do the task. Show the model per agent in the plan. The user's choice always wins.

- `haiku`: mechanical and well-defined – running tests/builds, formatting, simple edits, search/summarize, docs.
- `sonnet`: normal implementation, tests, bug fix with known cause, review.
- `opus`: architecture, unclear bug cause, large refactors, final review.
- `fable`: never, unless the user explicitly asks for it. Don't suggest it.

Two failed attempts → suggest a larger model (at most `opus`).

## Workflow

1. **Plan** in `tasks.json`: `{id, title, acceptance[], depends_on[], owner, state, attempts}`. Show the plan (agents and models) before starting.
2. **Dispatch** only tasks whose dependencies are `done`. One task per agent.
3. **Wait** with `Monitor` on `tail -f ~/.claude/herd/<HID>/inbox/orchestrator.log`. Read `reports/<id>.md`.
4. **Review** with a separate agent against `acceptance`. Only send relevant findings back.
5. **Max 3 attempts**, then ask the user.
6. **Isolation:** several coding agents in a git repo → a dedicated `git worktree` per agent as `cwd`. Ask before merging.
7. **Report** briefly when a task changes state or needs a decision.
