<p align="center">
  <img src="https://img.shields.io/badge/Rust-000000?style=for-the-badge&logo=rust&logoColor=white" alt="Rust"/>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter"/>
  <img src="https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white" alt="Swift"/>
  <img src="https://img.shields.io/badge/Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig"/>
  <img src="https://img.shields.io/badge/Metal-A2AAAD?style=for-the-badge&logo=apple&logoColor=white" alt="Metal"/>
</p>

<h1 align="center">
  <br>
  <img src="flutter_app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="80" alt="Tether icon"/>
  <br>
  Tether
  <br>
</h1>

<h4 align="center">An organized terminal for macOS — GPU-accelerated, with first-class SSH and AI tool awareness.</h4>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#building-the-terminal-library">Building the terminal library</a>
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Tether screenshot" width="780"/>
</p>

---

## Features

### GPU-accelerated terminal
Powered by [libghostty](https://ghostty.org) — the same rendering engine as the Ghostty terminal app. Metal-native, pixel-perfect fonts (subpixel hinting, ligatures, Nerd Fonts, emoji), and true 24-bit color. Idle sessions consume zero GPU budget.

### Organized sessions
- **Hierarchical groups** — nest sessions into folders, each with its own working directory
- **Drag & drop** — reorder sessions and groups in the sidebar
- **Persistent across restarts** — sessions and group structure survive server restarts

### SSH remote sessions
- **Zero-config remote terminals** — point a group at an SSH host; Tether automatically deploys a server process on the remote, establishes a tunnel, and surfaces the remote sessions in your local sidebar
- **Transparent reconnect** — sessions reappear in their original groups when the SSH host comes back online
- **Live connection status** — sidebar shows each host's state (Connecting / Ready / Failed)

### AI tool awareness
When Claude Code or Codex is running inside a session, a small dot appears on the tab and sidebar entry:
- **Green + pulsing** — tool is actively running
- **Amber** — tool is waiting for your input

Works for both local and remote SSH sessions.

### macOS integration
- **Global hotkey** — bring the app to the foreground from anywhere with a configurable keyboard shortcut
- **Configurable font** — font family, size, and custom key bindings from the settings panel

---

## Quick Start

### Prerequisites

```bash
brew install zig          # 0.13+
brew install flutter      # 3.7+
brew install rust         # 1.75+
```

### 1. Build the terminal library

```bash
./scripts/build_libghostty.sh
```

### 2. Start the server

```bash
cargo run -p tether-server -- --port 7680
```

### 3. Run the app

```bash
cd flutter_app
flutter pub get
cd macos && pod install && cd ..
flutter run -d macos
```

The app connects to `http://localhost:7680` automatically.

---

## Architecture

```
Flutter app (macOS)
    │
    │  HTTP — session/group metadata
    ▼
tether-server (Rust)
    │
    │  SSH tunnel + WebSocket — terminal I/O for remote sessions
    ▼
tether-server on SSH host

macOS native layer (Swift + libghostty.a)
    PTY + Metal rendering, entirely in-process for local sessions
```

Local sessions never leave the app — the PTY and GPU surface live inside libghostty. Remote SSH sessions are proxied through the server over an SSH tunnel.

---

## Building the terminal library

```bash
# Default (v1.1.3)
./scripts/build_libghostty.sh

# Override version
GHOSTTY_TAG=v1.1.4 ./scripts/build_libghostty.sh
```

Produces `libghostty.a` and `ghostty.h` in `flutter_app/macos/Runner/ghostty/`. The `.ghostty_build/` checkout is excluded from git; rebuild only when upgrading Ghostty.

---

## Tech Stack

| | |
|---|---|
| Terminal engine | [libghostty](https://ghostty.org) (Zig) |
| GPU rendering | Metal |
| App | Flutter / Dart / Riverpod |
| Server | Rust / Axum / SQLite |
| Native bridge | Swift / FlutterPlatformView |

## License

MIT
