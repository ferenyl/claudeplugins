# ferenyl-zellij

```
/plugin install ferenyl-zellij@ferenyl
```

Requires `zellij >= 0.45` and `jq`.

Installs a `SessionStart` hook that reloads active sessions after `/clear`, compact and resume.

## Skill: `orchestrator`

Turns the current Claude session into an orchestrator. It creates a dedicated Zellij session (`claude-<name>`), starts Claude agents with any purpose in tabs or panes, keeps track of them (even after `/clear`) and relays communication between them. Agents can also talk to each other directly. Work is broken down into bounded tasks with dependencies, reviewed by a separate agent and reported back.

**Invocation**

```
/ferenyl-zellij:orchestrator
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
| Rename session | "Rename the session to claude-payments" |
| Send message | "Ask api-dev to add rate limiting" |
| Status | "Show all agents and their status" |
| Shut down | "Shut down the project" |

The session is named after what you are working on, e.g. `claude-auth-api`. Attach with `zellij attach claude-<name>`. The first tab (`orchestrator`) shows a dashboard with agents, tasks and messages. It is recreated automatically if closed while agents exist, and goes away when the session ends.

Each agent gets a model based on how hard the task is (`haiku` for simple, `sonnet` for normal implementation, `opus` for hard). `fable` is only used when you explicitly ask for it. Models are shown in the plan before start and can be changed at any time.

Agents in a directory Claude Code doesn't trust yet are only started after you approve it.

State is stored in `~/.claude/herd/<herd-id>/`.
