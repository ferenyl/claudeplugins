# claudeplugins

Claude Code plugin marketplace `ferenyl`.

## Plugins

| Plugin | Beskrivning |
|---|---|
| [`ferenyl-zellij`](plugindocs/ferenyl-zellij.md) | Orkestrera Claude-agenter i Zellij |

## Installation

```
/plugin marketplace add ferenyl/claudeplugins
/plugin install ferenyl-zellij@ferenyl
```

### Från lokal klon

```
/plugin marketplace add /sökväg/till/claudeplugins
/plugin install ferenyl-zellij@ferenyl
```

### Per projekt

Lägg i projektets `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ferenyl": { "source": { "source": "github", "repo": "ferenyl/claudeplugins" } }
  },
  "enabledPlugins": { "ferenyl-zellij@ferenyl": true }
}
```

### Uppdatera

```
/plugin marketplace update ferenyl
```

### Lokal utveckling

```bash
claude --plugin-dir ./plugins/ferenyl-zellij
```

## Struktur

```
.claude-plugin/marketplace.json        # marketplace: ferenyl
plugins/<plugin>/
├── .claude-plugin/plugin.json
├── hooks/hooks.json                   # valfri
└── skills/<skill>/SKILL.md
plugindocs/<plugin>.md                 # dokumentation per plugin
```

Plugins heter `ferenyl-<namn>` och anropas som `/ferenyl-<namn>:<skill>`. Ny plugin: skapa `plugins/ferenyl-<namn>/`, lägg till den i `marketplace.json` och skriv `plugindocs/ferenyl-<namn>.md`.
