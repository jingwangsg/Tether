<p align="center">
  <img src="flutter_app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="Tether icon"/>
</p>

<h1 align="center">Tether</h1>

<p align="center">
  <strong>The terminal that keeps up with how you actually work.</strong><br/>
  Organized sessions. Seamless SSH. Knows when Claude Code is thinking.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-Apple_Silicon-black?style=flat-square&logo=apple" alt="macOS"/>
  <img src="https://img.shields.io/badge/renderer-Metal-A2AAAD?style=flat-square&logo=apple" alt="Metal"/>
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"/>
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Tether screenshot" width="800"/>
</p>

---

## What makes it different

**Most terminals give you a window and get out of the way.** Tether organizes your work: sessions live in groups, groups can point to remote machines, and the sidebar tells you what's happening at a glance — including whether an AI tool is waiting for you.

Under the hood it's built on [Ghostty](https://ghostty.org)'s GPU rendering engine. Metal-native, subpixel-precise fonts, zero GPU cost when idle.

---

## Features

**Organized sessions**
Nest sessions into named groups with their own working directories. Drag to reorder. Everything persists across restarts.

**Remote SSH sessions that just work**
Point a group at an SSH host. Tether deploys itself on the remote, tunnels in, and your remote sessions appear in the sidebar alongside local ones — in the same group, every time you reconnect.

**AI tool awareness**
A small dot on each session tab shows what Claude Code or Codex is doing right now:

- 🟢 pulsing — running
- 🟡 static — waiting for you

Works for local and remote sessions alike.

**Global hotkey**
One keystroke brings Tether to the front from anywhere on your Mac, even when you're deep in another app.

**GPU-accelerated rendering**
Pixel-perfect text, ligatures, Nerd Font glyphs, true 24-bit color — rendered directly to Metal. The rendering core is the same one powering the Ghostty terminal app.

---

## Quick Start

```bash
# Prerequisites
brew install zig flutter rust

# 1. Build the terminal engine
./scripts/build_libghostty.sh

# 2. Start the server
cargo run -p tether-server -- --port 7680

# 3. Run the app
cd flutter_app && flutter pub get
cd macos && pod install && cd ..
flutter run -d macos
```

---

## Architecture

Local sessions run entirely in-process — PTY and Metal surface live inside `libghostty.a`, nothing leaves the app. Remote sessions are proxied over an SSH tunnel to a `tether-server` instance running on the host.

```
Flutter app  ──HTTP──▶  tether-server (local)
                              │
                         SSH tunnel
                              │
                              ▼
                        tether-server (remote host)
```

---

## License

MIT
