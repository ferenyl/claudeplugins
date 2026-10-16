# claudeplugins

Claude Code plugin marketplace `ferenyl`.

## Plugins

| Plugin | Description |
|---|---|
| [`ferenyl-claude`](plugindocs/ferenyl-claude.md) | Orchestrate Claude agents in Zellij |

## Installation

```
/plugin marketplace add ferenyl/claudeplugins
/plugin install ferenyl-claude@ferenyl
```

### From a local clone

```
/plugin marketplace add /path/to/claudeplugins
/plugin install ferenyl-claude@ferenyl
```

### Per project

Add to the project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ferenyl": { "source": { "source": "github", "repo": "ferenyl/claudeplugins" } }
  },
  "enabledPlugins": { "ferenyl-claude@ferenyl": true }
}
```

### Update

```
/plugin marketplace update ferenyl
```

### Local development

```bash
claude --plugin-dir ./plugins/ferenyl-claude
```

## Structure

```
.claude-plugin/marketplace.json        # marketplace: ferenyl
plugins/<plugin>/
├── .claude-plugin/plugin.json
├── hooks/hooks.json                   # optional
└── skills/<skill>/SKILL.md
plugindocs/<plugin>.md                 # documentation per plugin
```

Plugins are named `ferenyl-<name>` and invoked as `/ferenyl-<name>:<skill>`. To add a plugin: create `plugins/ferenyl-<name>/`, add it to `marketplace.json` and write `plugindocs/ferenyl-<name>.md`.
