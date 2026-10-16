# claudeplugins

Claude Code plugin marketplace `ferenyl`.

## Plugins

| Plugin | Beskrivning |
|---|---|
| `zellij` | Orkestrera Claude-agenter i Zellij |

## Installation

```
/plugin marketplace add ferenyl/claudeplugins
/plugin install zellij@ferenyl
```

### Per projekt

Lägg i projektets `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ferenyl": { "source": { "source": "github", "repo": "ferenyl/claudeplugins" } }
  },
  "enabledPlugins": { "zellij@ferenyl": true }
}
```

### Uppdatera

```
/plugin marketplace update ferenyl
```

### Lokal utveckling

```bash
claude --plugin-dir ./plugins/zellij
```

## zellij

Kräver `zellij >= 0.45` och `jq`.

### Skill: `zellij-orchestrator`

Gör den aktuella Claude-sessionen till orkestrerare. Den skapar en egen Zellij-session (`claude-<id>`), startar Claude-agenter med valfria syften i tabbar eller panes, håller register över dem (även efter `/clear`) och förmedlar kommunikation mellan dem. Arbetet bryts ned i avgränsade uppgifter med beroenden, granskas av en separat agent och rapporteras tillbaka.

**Anrop**

```
/zellij:zellij-orchestrator
```

Eller beskriv vad du vill göra, så laddas skillen automatiskt:

| Vad | Exempel |
|---|---|
| Nytt projekt | "Skapa ett nytt orkestrerat projekt i `~/projects/my-app`" |
| Skapa agent | "Starta en agent för API-utveckling i en ny tabb" |
| Skapa agent i pane | "Starta en testagent i en pane bredvid api-dev" |
| Flytta agent | "Flytta test-agenten till en egen tabb" |
| Stäng agent | "Stäng docs-agenten" |
| Skicka meddelande | "Be api-dev lägga till rate limiting" |
| Status | "Visa alla agenter och deras status" |
| Avsluta | "Stäng ner projektet" |

Anslut till sessionen med `zellij attach claude-<id>`. Första tabben (`herd`) visar en dashboard med agenter, uppgifter och meddelanden.

State sparas i `~/.claude/herd/<session>/`.
