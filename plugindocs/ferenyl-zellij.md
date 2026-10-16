# ferenyl-zellij

```
/plugin install ferenyl-zellij@ferenyl
```

Kräver `zellij >= 0.45` och `jq`.

Installerar en `SessionStart`-hook som läser in aktiva sessioner igen efter `/clear`, compact och resume.

## Skill: `orchestrator`

Gör den aktuella Claude-sessionen till orkestrerare. Den skapar en egen Zellij-session (`claude-<id>`), startar Claude-agenter med valfria syften i tabbar eller panes, håller register över dem (även efter `/clear`) och förmedlar kommunikation mellan dem. Arbetet bryts ned i avgränsade uppgifter med beroenden, granskas av en separat agent och rapporteras tillbaka.

**Anrop**

```
/ferenyl-zellij:orchestrator
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
