# ferenyl-claude

```
/plugin install ferenyl-claude@ferenyl
```

Requires `zellij >= 0.45` and `jq`.

Installs a `SessionStart` hook that reloads active sessions after `/clear`, compact and resume.

## Skill: `drover`

Turns the current Claude session into a drover that herds a team of Claude agents. It creates a dedicated Zellij session (`corral-<name>-<id>`), starts Claude agents with any purpose in tabs or panes, keeps track of them (even after `/clear`) and relays communication between them. Agents can also talk to each other directly. Work is broken down into bounded tasks with dependencies, reviewed by a separate agent and reported back.

**Invocation**

```
/ferenyl-claude:drover
```

Or describe what you want to do and the skill loads automatically:

| What | Example |
|---|---|
| New project | "Create a new orchestrated project in `~/projects/my-app`" |
| Spawn agent | "Start an agent for API development in a new tab" |
| Spawn agent in pane | "Start a test agent in a pane next to api-dev" |
| Move agent | "Move the test agent to its own tab" |
| Close agent | "Close the docs agent" |
| Change model | "Switch api-dev to opus" |
| Rename session | "Rename the session to payments" |
| Choose name up front | "Create a new project in `~/projects/my-app` named billing-v2" |
| Send message | "Ask api-dev to add rate limiting" |
| Status | "Show all agents and their status" |
| Shut down | "Shut down the project" |

The session is named after what you are working on plus a fixed id, e.g. `corral-auth-api-1a2b3c4d`. Attach with `zellij attach corral-<name>-<id>`. The first tab (`corral`) shows a dashboard with agents, tasks and messages. It is recreated automatically if closed while agents exist, and goes away when the session ends.

Each agent gets a model based on how hard the task is (`haiku` for simple, `sonnet` for normal implementation, `opus` for hard). `fable` is only used when you explicitly ask for it. Models are shown in the plan before start and can be changed at any time.

Agents in a directory Claude Code doesn't trust yet are only started after you approve it.

The drover asks you to rename its own Claude session to `drover-<name>-<id>` (via `/rename`). The id never changes, even when the session is renamed, so you can always see which drover and corral belong together.

State is stored in `~/.claude/drover/<drover-id>/`.
