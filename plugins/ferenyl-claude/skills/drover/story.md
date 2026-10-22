# Story mode
The user works from issues/work items/stories. State: `<HID>/stories.json`, `<HID>/stories/<sid>.md` (description + clarifications; agents read it, never paste it).

```
drover.sh story <HID> fetch <ref...> [repo=o/r] [tracker=github|azure|jira] [org=URL] [query="..."] [id=<sid>]
drover.sh story <HID> add <sid> "<title>" [tracker= key= url= source= type= assignee= state= file=F]   # import after an MCP fetch
drover.sh story <HID> mode parallel|sequential [planner=y|n] [pr=y|n] [pr_review=y|n] [azure_config=DIR|-]
drover.sh story <HID> set <sid> [status=S|auto] [blocked="reason"|-] [order=N] [clarify="answer"] [branch=B] [worktree=W] [assignee=A] [pr=<url|nr>|-]
drover.sh story <HID> list | show <sid>          # also refresh open PRs, at most once per 60 s
drover.sh story <HID> assign <sid>              # tracker assignee = current CLI user
drover.sh story <HID> comment <sid> "<text>"    # comment on the work item
drover.sh story <HID> pr <sid> [--draft] [--title T] [--body-file F]   # push branch, create PR; `set <sid> pr=<url|nr>` records one an agent made via MCP
drover.sh story <HID> sync                      # refresh PR state/review
spawn ... --story <sid>  ·  worktree <HID> <sid>-<role> --story <sid>  ·  task add ... story=<sid> kind=plan|impl|review|pr
```
Refs: issue URL/`#N` (github), work item URL/id (azure), `KEY-12`/browse URL (jira). Exit 5 = CLI missing/unauthenticated: fetch/write via the tracker MCP, then `story add` / `story set`. Azure: if `az` fails on auth, the user may be logged in from another folder: look in the instructions in effect (CLAUDE.md) for an az config path, else ask the user whether there is an az login in another folder; then `story mode azure_config=DIR` (exported as AZURE_CONFIG_DIR for every az call) and retry.
Statuses: backlog · planning · working · waiting-for-user · review · done; derived from tasks/agents/PR. `status=S` pins one, `status=auto` unpins. `blocked=` is a badge, not a status.

## Flow
1 `story fetch` (or MCP + `story add`), show `story list`.
2 Unclear story (what is wrong/what to do?): `story set <sid> status=waiting-for-user`, ask the user, then `story set <sid> clarify="..."` (unpins). Ask whether to post the answer on the work item → `story comment`.
3 One AskUserQuestion batch (`pr=y` = the user already said yes to commit + push + PR after a green review: do it without asking again; ask again only on blocking findings or changed scope): sequential or parallel (parallel ⇒ one worktree per story) · planner? (skip if the user asked for one) · PR when done? · if PR: PR review? · assign the work items to you? → `story mode ...`; on yes `story assign` each.
  Sequential: stories by `order`, one at a time, one branch per story (`story set <sid> branch=`).
4 Planner first (if chosen): spawn it before any other agent; tasks `kind=plan story=<sid>` (one planner for all, or `<sid>-plan` per story when parallel). It plans the solution and the agents+models per story into a plan file. Models: opus plans the contract (shared design, interfaces); sonnet plans each small story. The plan template requires per story: a verified test command (it was run), build prerequisites, line endings (repo convention), and the consumers of every changed DTO/interface. Show its agents to the user before spawning; once the plan is accepted switch yourself to sonnet (`/model sonnet`); every other story task `depends=` its plan task.
5 Story agents (small story: the dev writes its tests, one shared `review` agent reviews all stories, the full test suite runs once at the end, not per story): id `<sid>-<role>`, `spawn ... --story <sid>`; tasks `<sid>-<name>` (story is inherited from the owner). Parallel: `worktree <HID> <sid>-dev --story <sid>` as cwd.
6 "How is story X / the stories going?": `story show <sid>` / `story list`, not `read`.
7 Never write statuses to trackers; tracker writes are only `assign` and `comment`, each after the user said yes.
8 Branch names, commit messages and PR title/body are not hardcoded: before branching/committing/opening a PR read the instructions in effect (global + project CLAUDE.md, CONTRIBUTING, PR templates), follow them (`worktree --branch <name>`, `story pr --title/--body-file`), and ask the user if nothing is specified. Story tasks done: PR (ask unless answered in 3) → `story pr <sid>`. Review wanted: spawn `<sid>-review` (sonnet; opus for large diffs), task `kind=review`, reviews the PR diff; posts review comments only if the user agreed. `story sync` before reporting PR state. Ask before merging. User says a PR is merged, or the next story starts: `story sync`, check `story list` (merged ⇒ `done`), then the next worktree from a fresh `git fetch` + `origin/main`. No PR: after the user accepts, `story set <sid> status=done`.
