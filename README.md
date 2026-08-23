# ClayHub

> A personal macOS menu bar toolbox: bind mouse side buttons to shortcuts,
> and manage MCP servers and ordinary local services from a GUI.

ClayHub is a lightweight native (SwiftUI) menu bar app with two features:

1. **Mouse side-button binding** — listen for mouse side buttons (button 4 & 5)
   and simulate configurable keyboard shortcuts.
2. **Service manager** — run, monitor, and add MCP servers or ordinary local
  services. MCP entries are also synced into ZCode's config.

## Features

- Menu bar app — no dock icon clutter
- Bind side buttons to any keyboard shortcut (e.g. `⌘D`, `⌘R`, `⌃⇧Tab`)
- Enable or disable SideClick immediately; the choice is restored on the next app launch
- Persist bindings across launches
- Service manager GUI: add / edit / remove services, enable / disable / restart, view logs
- Runs local services as supervised process trees (no more "lost" background processes)
- Enabled services start with ClayHub and their process trees stop when ClayHub exits
- Syncs managed servers into ZCode (`~/.zcode/cli/config.json`)
- Includes a loopback-only Qwen multimodal API MCP (`qwen-mm-api`), with its
  DashScope key, endpoint and model selection stored in the ClayHub service
  environment instead of a separate Qwen config file
- Launch at login toggle

## Requirements

- macOS 13 (Ventura) or later
- A mouse with side buttons (for the click-binding feature)
- Node.js / `npx` (for the bundled local exa-search bridge)
- Python + `uv` (for the bundled vision-mcp server)
- Network access when installing or updating the optional CLIProxyAPI service

## Permissions

ClayHub requires Accessibility permission for the click-binding feature:

| Permission | Purpose |
|---|---|
| **Accessibility** | Listen for side-button events and simulate shortcuts via `CGEvent` |

Grant it in **System Settings → Privacy & Security → Accessibility**. ClayHub
uses an active event tap so it can consume a configured mouse event; Accessibility
covers both that listener and shortcut posting.

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
RESET_PERMISSIONS=1 ./Scripts/restart-app.sh
```

Regular `./Scripts/restart-app.sh` runs preserve permissions. Builds use an
Apple code-signing identity when one is available; otherwise the build script
creates a stable ClayHub-only local identity so privacy approval survives rebuilds.

Run the SwiftPM executable directly during development:

```bash
swift run ClayHub
```

## Managed Services

The **Services** window (menu bar → Services) lists all managed services
with live status, enable/disable controls, and logs. An enabled entry is part of
the Hub lifecycle: it starts immediately (and on future ClayHub launches), and
stops immediately when disabled or when ClayHub exits. Click **Add Service** to
add either an MCP server or an ordinary local process.

Five services are pre-seeded. Existing installations receive the DeepSeek
Harness, Qwen, and CLIProxyAPI entries through versioned one-time migrations:

| Name | Type | Notes |
|---|---|---|
| `vision-mcp` | MCP / HTTP | Local vision analysis server at `http://127.0.0.1:8766/mcp` |
| `exa-search` | MCP / HTTP | Local exa search, bridged via `supergateway` at `http://127.0.0.1:8767/mcp` |
| `qwen-mm-api` | MCP / HTTP | Qwen VL/Omni tools at `http://127.0.0.1:8768/mcp`; the v2 migration keeps `vision-mcp` but disables it |
| `deepseek-harness` | Local service | Runs `dsh web` at `http://127.0.0.1:3080` using the bundled Node 24 toolchain |
| `cli-proxy-api` | Local service | Optional OpenAI/Gemini/Claude/Codex-compatible API proxy at `http://127.0.0.1:8317` |

Enabled MCP entries are written into `~/.zcode/cli/config.json` (`mcp.servers`)
so ZCode sessions pick them up automatically. Local-service entries such as
`deepseek-harness` are intentionally not written there. The first launch of
`exa-search` may be slow because `npx` downloads its dependencies.

> The `exa-search` server needs an `EXA_API_KEY`. On first run ClayHub tries to
> reuse the key from an existing ZCode config; otherwise edit the server and add
> `EXA_API_KEY=...` to its environment.

> `qwen-mm-api` keeps `DASHSCOPE_API_KEY`, `DASHSCOPE_BASE_URL`, and the default
> VL/Omni model names in the ClayHub service environment. Click its key button
> in Services to paste the API key; saving restarts the server immediately.

### CLIProxyAPI

`cli-proxy-api` is a local API proxy, not an MCP server. It is disabled until
you click **Install** in the Services window. ClayHub downloads the official
macOS build, verifies its SHA-256 checksum, creates a loopback-only config at
`~/.cli-proxy-api/config.yaml`, and then starts it as a ClayHub-owned service.
The generated config uses port `8317` and keeps authentication files in
`~/.cli-proxy-api`.

The first OAuth login is provider-specific and should be completed once from a
Terminal. For example, Codex login is:

```bash
/Users/you/Library/Application\ Support/ClayHub/Services/CLIProxyAPI/current/cli-proxy-api \
  --codex-login
```

After login, point an OpenAI-compatible client at
`http://127.0.0.1:8317/v1` and use an API key from the generated config.
Do not also run `brew services start cliproxyapi`; ClayHub must be the only
process owner if it is expected to start and stop CLIProxyAPI with the app.

## Default Bindings

The **Enabled** switch in the SideClick window controls the mouse listener. It
is independent from **Launch at login**, which only controls whether ClayHub
itself starts automatically when you log in to macOS.

| Button | Shortcut |
|---|---|
| Side Button (Back) | `⌘D` |
| Side Button (Forward) | `⌘R` |

## License

MIT
