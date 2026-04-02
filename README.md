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

<h4 align="center">Tether's organized terminal interface — GPU-accelerated, Metal-native rendering.</h4>

<p align="center">
  <a href="#why">Why</a> •
  <a href="#features">Features</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#building-the-terminal-library">Building the terminal library</a> •
  <a href="#project-structure">Project Structure</a>
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Tether screenshot" width="780"/>
</p>

---

## Why?

[Tether](../Tether) uses `xterm.dart` — a JavaScript-lineage terminal renderer ported to Dart. It works everywhere but carries the limitations of a software renderer: font hinting artifacts, ligature gaps, and a rendering budget that competes with Flutter's own frame budget.

**Tether** replaces the terminal widget with a GPU-accelerated, Metal-native rendering core. The result is pixel-perfect text, zero-compromise font rendering, and a PTY stack that runs entirely in-process via a Zig-compiled static library. The sidebar, session management, SSH awareness, and group hierarchy are unchanged — they're the same Tether code talking to the same Rust server.

## Features

### GPU-Accelerated Rendering
- **Metal rendering** — libghostty renders directly to a CAMetalLayer; Flutter composites on top. No pixel readback, no CPU blitting.
- **Pixel-perfect fonts** — subpixel hinting, ligatures, Nerd Font glyphs, and bitmap emoji all rendered by Ghostty's font pipeline (CoreText + custom rasterizer)
- **Event-driven draw loop** — libghostty's `wakeup_cb` triggers redraws only when the terminal state changes; idle sessions consume no GPU budget
- **True color + 256-color** — full VT/xterm-256 palette, 24-bit RGB, and italics

### Terminal
- **Local PTY** — spawned in-process by libghostty via `posix_openpt`; no external process manager needed for basic use
- **Full keyboard support** — modifier keys, arrow keys, function keys, Ctrl combos, dead keys, IME input
- **Bracketed paste** — handled internally by libghostty; `Cmd+V` routes through the native pasteboard
- **Scrollback** — managed inside libghostty's PageList (same implementation as Ghostty app)
- **Session titles** — OSC 0/2 escape sequences update tab names automatically; PUA/Nerd Font glyphs stripped before display

### Organization
- **Hierarchical groups** — nested folders with inherited working directories
- **Persistent sessions** — metadata (name, shell, cwd, group) survives restarts via SQLite
- **Drag & drop reordering** — reorder sessions and nested groups within the sidebar
- **SSH host association** — bind groups to SSH hosts; sessions in that group are spawned on the remote server
- **Group assignment persistence** — SSH sessions remember their local group across server restarts via `session_group_registry`

### SSH & Remote Sessions
- **Remote daemon management** — automatically deploys and maintains a `tether-server` process on each SSH host via `~/.ssh/config`
- **SSH tunnel proxying** — local server establishes a port-forward tunnel to each remote server; all session API calls and terminal I/O are proxied through it
- **Session sync** — remote sessions are mirrored into the local group hierarchy on connect and kept in sync
- **WebSocket terminal I/O** — for SSH-proxied sessions, terminal input/output is streamed over WebSocket through the tunnel; local PTY sessions never use WebSocket
- **Scrollback replay** — on reconnect, the full scrollback buffer is replayed from the remote server
- **SSH host status** — sidebar shows reachable SSH hosts from `~/.ssh/config` with live connection state (Connecting / Deploying / Ready / Failed)

### Tool State Awareness
- **Live foreground process** — detects the active process in each terminal session (local and SSH)
- **Claude Code / Codex indicator** — small colored dot on session tabs and sidebar entries when an AI coding tool is active:
  - Green + pulsing = tool is actively running / generating output
  - Amber + static = tool is waiting for user input
- Detection is based on OSC title sequences, terminal output patterns, and alternate-screen state

### Platform
- **macOS native** — Apple Silicon (aarch64) with a direct Metal surface; no Rosetta, no translation layer
- **Global hotkey** — configurable system-wide shortcut to show/hide the app from any macOS context (requires Accessibility permission)
- **Settings panel** — font family, font size, global hotkey, custom key bindings
- **Pluggable backend** — `TerminalBackend` abstraction; macOS uses `NativeBackend`, other platforms fall back to `XtermBackend`

## Architecture

```
Flutter App (Dart / macOS)
┌─────────────────────────────────────────────────────┐
│  HomeScreen                                          │
│  ┌──────────────┐   ┌────────────────────────────┐  │
│  │   Sidebar    │   │       TerminalArea          │  │
│  │  (groups,    │   │  ┌──────────────────────┐   │  │
│  │   sessions,  │   │  │  TerminalView         │   │  │
│  │   SSH hosts, │   │  │  AppKitView (native)  │   │  │
│  │   tool dots) │   │  └──────────────────────┘   │  │
│  │              │   │  MethodChannel: input        │  │
│  │  Riverpod    │   │  EventChannel:  title/exit   │  │
│  │  providers   │   └────────────────────────────┘  │
│  └──────────────┘                                    │
└─────────────────┬───────────────────────────────────┘
                  │ HTTP REST (metadata)
                  ▼
┌─────────────────────────────────────────────────────┐
│  tether-server  (Rust / Axum)                        │
│  ┌──────────────────────────────────────────────┐   │
│  │ REST API                                      │   │
│  │  /api/groups   /api/sessions                  │   │
│  │  /api/ssh/hosts  /api/remote/hosts            │   │
│  │  /api/completions  /api/completions/remote    │   │
│  ├──────────────────────────────────────────────┤   │
│  │ WebSocket  /ws/session/{id}                   │   │
│  │  (terminal I/O for SSH-proxied sessions only) │   │
│  ├──────────────────────────────────────────────┤   │
│  │ SQLite — groups, sessions, session_group_     │   │
│  │          registry (group assignment cache)    │   │
│  ├──────────────────────────────────────────────┤   │
│  │ RemoteManager — per-host state machine        │   │
│  │  Unreachable → Connecting → Deploying →       │   │
│  │  Ready → (tunnel port assigned)               │   │
│  └──────────────────────────────────────────────┘   │
└───────────────┬─────────────────────────────────────┘
                │ SSH tunnel (localhost:XXXX → remote:7680)
                ▼
┌─────────────────────────────────────────────────────┐
│  Remote tether-server  (on SSH host)                 │
│  — identical binary; manages PTY sessions on host    │
│  — same REST + WebSocket API                         │
└─────────────────────────────────────────────────────┘

macOS Native  (Swift + libghostty.a)
┌─────────────────────────────────────────────────────┐
│  TerminalPlugin  FlutterPlatformViewFactory          │
│  TerminalApp     singleton ghostty_app_t             │
│  TerminalView    NSView subclass                     │
│  ├── ghostty_surface_t  (PTY + Metal, in libghostty) │
│  └── wakeup_cb → ghostty_app_tick() → surface_draw() │
└─────────────────────────────────────────────────────┘

libghostty.a  (Zig — compiled from ghostty-org/ghostty)
    ghostty_init / ghostty_app_new / ghostty_surface_new
    ghostty_surface_draw / ghostty_surface_set_size
    ghostty_surface_key / ghostty_surface_text
    ghostty_surface_mouse_* / ghostty_surface_free
```

**Key design choices:**

- **Local vs remote I/O** — for local sessions, the PTY lives entirely in-process inside libghostty; no WebSocket, no server round-trip. For SSH sessions, the PTY runs on the remote tether-server and terminal I/O is streamed over WebSocket through the SSH tunnel.
- **`?local=true`** — sessions created with this flag are stored in SQLite but skip `PtySession::spawn()`; the PTY is owned by the native terminal library on the client side.
- **Event-driven rendering** — the terminal library calls `wakeup_cb` from any thread when it has output to paint. A coalescing dispatcher on the main queue calls `ghostty_app_tick()` then redraws only the active surface. Offstage tabs are unregistered from the drawable set so they don't burn GPU time.
- **Group registry** — `session_group_registry` is a write-ahead table that records each SSH session's local group assignment. `delete_all_sessions()` (called on startup) clears the sessions table but preserves the registry, so sessions reconnect to their original groups rather than falling back to the sync-provided default.

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
# Clones ghostty-org/ghostty at v1.1.3, builds with zig, copies:
#   flutter_app/macos/Runner/ghostty/libghostty.a
#   flutter_app/macos/Runner/ghostty/ghostty.h
```

### 2. Start the metadata server

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

> The app connects to `http://localhost:7680` automatically. Create a group, open a session — you get a full Metal-rendered terminal inside the Tether UI.

## Building the terminal library

The build script pins a specific release tag and produces a fat-free `aarch64-macos` static library:

```bash
# Default tag (v1.1.3)
./scripts/build_libghostty.sh

# Override tag
GHOSTTY_TAG=v1.1.4 ./scripts/build_libghostty.sh
```

The script:
1. Clones `ghostty-org/ghostty` at the pinned tag into `.ghostty_build/` (reuses existing checkout on subsequent runs)
2. Runs `zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos libghostty`
3. Copies `libghostty.a` and `ghostty.h` into `flutter_app/macos/Runner/ghostty/`

The `.ghostty_build/` directory is excluded from git. Rebuild only when upgrading Ghostty.

## Project Structure

```
tether/
├── crates/
│   └── tether-server/
│       └── src/
│           ├── api/               # REST endpoints
│           │   ├── groups.rs      # /api/groups
│           │   ├── sessions.rs    # /api/sessions
│           │   ├── ssh.rs         # /api/ssh/hosts
│           │   ├── remote.rs      # /api/remote/hosts
│           │   └── completions.rs # /api/completions[/remote]
│           ├── remote/            # SSH remote session management
│           │   ├── manager.rs     # Per-host state machine
│           │   ├── tunnel.rs      # SSH port-forward tunnel
│           │   ├── deploy.rs      # Remote binary deployment
│           │   ├── sync.rs        # Session list sync
│           │   └── client.rs      # HTTP client to remote server
│           ├── pty/               # PTY lifecycle (local sessions)
│           ├── persistence/       # SQLite — groups, sessions, registry
│           ├── ws/                # WebSocket handler (SSH-proxied sessions)
│           ├── server.rs          # Axum router
│           ├── config.rs          # TOML config
│           ├── auth.rs            # Bearer token middleware
│           └── ssh_config.rs      # ~/.ssh/config parser
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart              # Backend selection: NativeBackend (macOS) / XtermBackend
│   │   ├── platform/
│   │   │   ├── terminal_backend.dart   # Abstract TerminalBackend interface
│   │   │   ├── native_backend.dart     # macOS: wraps TerminalView
│   │   │   ├── key_map.dart            # LogicalKeyboardKey → terminal key names
│   │   │   └── xterm_backend.dart      # Fallback / Android stub
│   │   ├── widgets/
│   │   │   ├── sidebar/           # Groups, sessions, SSH hosts
│   │   │   ├── tool_state_dot.dart     # Green/amber badge for Claude Code / Codex
│   │   │   └── terminal/
│   │   │       ├── terminal_view.dart        # AppKitView + MethodChannel/EventChannel
│   │   │       ├── terminal_area.dart        # Tab management, title sanitization
│   │   │       └── mobile_key_bar.dart       # On-screen modifier keys (mobile)
│   │   ├── providers/             # Riverpod: server, session, UI, settings
│   │   ├── services/              # REST API client
│   │   └── models/                # Group, Session, SSHHost
│   └── macos/Runner/
│       ├── Runner-Bridging-Header.h     # #import "ghostty/ghostty.h"
│       ├── TerminalPlugin.swift         # FlutterPlugin + PlatformViewFactory
│       ├── TerminalApp.swift            # Singleton ghostty_app_t + callbacks
│       ├── TerminalView.swift           # NSView: surface lifecycle, input, events
│       ├── HotkeyManager.swift          # Global hotkey (show/hide app)
│       ├── MainFlutterWindow.swift      # Registers TerminalPlugin
│       └── ghostty/
│           ├── ghostty.h                # C API header (ghostty library)
│           └── libghostty.a             # Built by build_libghostty.sh (not in git)
├── scripts/
│   └── build_libghostty.sh        # Zig build driver
├── demos/                         # Standalone integration demos (link → app → NSView → Flutter)
│   ├── demo1_link/                # Swift CLI: ghostty_init() links
│   ├── demo2_app/                 # ghostty_app_new() + stub callbacks
│   ├── demo3_nsview/              # Full terminal in a bare AppKit window
│   ├── demo4_flutter_view/        # PlatformView infra validation (no libghostty)
│   └── demo5_integration/         # Flutter + libghostty + MethodChannel input
└── Cargo.toml                     # Workspace root
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Terminal engine | [libghostty](https://ghostty.org) (Zig), compiled as `libghostty.a` |
| GPU rendering | Metal (via libghostty's CAMetalLayer) |
| Native bridge | Swift, `FlutterPlatformView`, `MethodChannel`, `EventChannel` |
| App framework | Flutter 3.7, Dart, Riverpod 2.6 |
| Metadata server | Rust, Axum 0.8, SQLite (rusqlite) |
| Remote sessions | SSH tunnel + WebSocket proxy |
| Font rendering | CoreText + Ghostty's custom rasterizer |
| Build toolchain | Zig 0.13 (for libghostty), Cargo (server), Flutter (app) |

## License

MIT
