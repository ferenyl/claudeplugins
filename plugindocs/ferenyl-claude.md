# ferenyl-claude

```
/plugin install ferenyl-claude@ferenyl
```

Requires `zellij >= 0.45` and `jq`.

Installs a `SessionStart` hook that reloads active sessions after `/clear`, compact and resume (for the drover only; agents skip it).

## Skill: `drover`

Starts a drover that herds a team of Claude agents. It creates a dedicated Zellij session (`corral-<name>-<id>`) with the drover itself running in its own Claude in the `drover` tab (default model `opus`), starts Claude agents with any purpose in tabs or panes, keeps track of them (even after `/clear`) and relays communication between them. Agents can also talk to each other directly. Work is broken down into bounded tasks with dependencies, reviewed against acceptance criteria and reported back.

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
| Status | "Show all agents and their status" (`busy`, `idle`, or `blocked` when an agent waits for your approval; a desktop notification is sent if `notify-send` exists) |
| Read agent screen | "Show what api-dev is doing" |
| Revive | "The zellij session died, bring the agents back" (relaunches them with `--resume`, each in its own tab; pane placement is not restored) |
| Shut down | "Shut down the project" |

The session is named after what you are working on plus a fixed id, e.g. `corral-auth-api-1a2b3c4d`. Attach with `zellij attach corral-<name>-<id>` (detach with Ctrl-o d); the launching session can then be closed. The launcher hands over with a brief file (`new --brief FILE`) and/or by forking its conversation (`new --fork`). Tab order is fixed: `corral` (dashboard with agents, tasks and messages) is always first, `drover` second; both are tracked by tab id and put back if you move them. The dashboard is recreated automatically if closed. If the drover tab or its Claude is gone, `revive` brings it back with `--resume`. `close` runs detached so the drover inside can shut its own session down. Mutating commands (`spawn`, `kill`, ...) are refused outside the drover pane unless `--force` is given as the second argument (`drover.sh <cmd> <HID> --force ...`).

Each agent gets a model based on how hard the task is (`haiku` for simple, `sonnet` for normal implementation, `opus` for hard). `fable` is only used when you explicitly ask for it. Models are shown in the plan before start and can be changed at any time.

Agents in a directory Claude Code doesn't trust yet are only started after you approve it.

The drover session is titled `drover-<name>-<id>` at launch, and `rename` keeps it in sync with the corral session (the title is reapplied after `/clear` and compact). The drover's settings pre-approve `drover.sh`. If auto mode still blocks `rename`, add `Bash(*drover.sh rename*)` to your permission rules. The id never changes, so you can always see which drover and corral belong together.

Token use is kept low: agents don't get the drover hook text, spawning or closing an agent doesn't ping the other agents (they read `registry.json` when they need peers), and the drover catches up once on recent inbox lines, then waits on the inbox log without replaying old lines or timestamps. Messages to a blocked agent are queued instead of typed into its approval dialog (`flush` delivers them), and delivery is verified with retries. Only one corral tab is kept (a single watcher dedupes). Agents are started with a clean Claude env so their transcripts and `--resume` work. Agents may call `drover.sh send` without prompts (pre-allowed in their settings).

State is stored in `~/.claude/drover/<drover-id>/`.
