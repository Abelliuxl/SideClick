# SideClick

> Bind your mouse side buttons to keyboard shortcuts on macOS.

SideClick is a lightweight menu bar app that listens for mouse side button
(clicks from button 4 & 5, i.e. back/forward) and simulates configurable
keyboard shortcuts when pressed.

## Features

- Menu bar app — no dock icon clutter
- Bind side buttons to any keyboard shortcut (e.g. `⌘D`, `⌘R`, `⌃⇧Tab`)
- Persist bindings across launches
- Minimal, native SwiftUI interface

## Requirements

- macOS 13 (Ventura) or later
- A mouse with side buttons (button 4 & 5)

## Permissions

SideClick requires two system permissions:

| Permission | Purpose |
|---|---|
| **Accessibility** | Simulate keyboard shortcuts via `CGEvent` |
| **Input Monitoring** | Listen for mouse side button events via `CGEventTap` |

Grant them in **System Settings → Privacy & Security**.

## Build & Run

```bash
./Scripts/build-app.sh
open SideClick.app
```

During development, use this to rebuild, clear stale privacy decisions, and
restart the app:

```bash
./Scripts/restart-app.sh
```

For development, you can also run the SwiftPM executable directly:

```bash
swift run SideClick
```

## Default Bindings

| Button | Shortcut |
|---|---|
| Side Button (Back) | `⌘D` |
| Side Button (Forward) | `⌘R` |

> **Tip for developers**: These defaults mimic VSCode's "Go to Definition" and
> "Rename Symbol" for quick code navigation.

## License

MIT
