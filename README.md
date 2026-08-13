# ClayHub

> A personal macOS menu bar toolbox: bind mouse side buttons to shortcuts,
> and manage local MCP servers from a GUI.

ClayHub is a lightweight native (SwiftUI) menu bar app with two features:

1. **Mouse side-button binding** — listen for mouse side buttons (button 4 & 5)
   and simulate configurable keyboard shortcuts.
2. **MCP server manager** — run, monitor, and add MCP servers as managed local
   processes, and sync them into ZCode's config so ZCode sessions can use them.

## Features

- Menu bar app — no dock icon clutter
- Bind side buttons to any keyboard shortcut (e.g. `⌘D`, `⌘R`, `⌃⇧Tab`)
- Persist bindings across launches
- MCP manager GUI: add / edit / remove servers, start / stop / restart, view logs
- Runs MCP servers as supervised local processes (no more "lost" background processes)
- Syncs managed servers into ZCode (`~/.zcode/cli/config.json`)
- Launch at login toggle

## Requirements

- macOS 13 (Ventura) or later
- A mouse with side buttons (for the click-binding feature)
- Node.js / `npx` (for the bundled local exa-search bridge)
- Python + `uv` (for the bundled vision-mcp server)

## Permissions

ClayHub requires two system permissions for the click-binding feature:

| Permission | Purpose |
|---|---|
| **Accessibility** | Simulate keyboard shortcuts via `CGEvent` |
| **Input Monitoring** | Listen for mouse side button events via `CGEventTap` |

Grant them in **System Settings → Privacy & Security**.

## Build & Run

```bash
./Scripts/build-app.sh
open ClayHub.app
```

Install into `/Applications` (required for the launch-at-login feature to work):

```bash
INSTALL=1 ./Scripts/build-app.sh
```

During development, rebuild and clear stale privacy decisions:

```bash
./Scripts/restart-app.sh
```

Run the SwiftPM executable directly during development:

```bash
swift run ClayHub
```

## MCP Servers

The **MCP Servers** window (menu bar → MCP Servers) lists all managed servers
with live status, start/stop controls, and logs. Click **Add Server** to add a
new one by hand — choose the transport (HTTP / SSE / stdio) and fill in either
a remote URL or a local process (command + arguments + environment).

Two servers are pre-seeded on first run:

| Name | Transport | Notes |
|---|---|---|
| `vision-mcp` | HTTP (local process) | Local vision analysis server at `http://127.0.0.1:8766/mcp` |
| `exa-search` | SSE (local process) | Local exa search, bridged via `supergateway` at `http://127.0.0.1:8767/sse` |

Managed servers are written into `~/.zcode/cli/config.json` (`mcp.servers`) so
ZCode sessions pick them up automatically. The first launch of `exa-search` may
be slow because `npx` downloads `supergateway` and `exa-mcp-server`.

> The `exa-search` server needs an `EXA_API_KEY`. On first run ClayHub tries to
> reuse the key from an existing ZCode config; otherwise edit the server and add
> `EXA_API_KEY=...` to its environment.

## Default Bindings

| Button | Shortcut |
|---|---|
| Side Button (Back) | `⌘D` |
| Side Button (Forward) | `⌘R` |

## License

MIT
