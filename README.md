# agentrocky

A macOS desktop companion app that puts a animated pixel-art character on your screen who you can chat with — powered by [Claude Code](https://claude.ai/code).

Rocky walks back and forth along the top of your Dock. Click him to open a terminal-style chat window and talk to Claude directly from your desktop.

## Features

- Animated sprite that walks across the bottom of your screen
- Click to open a popover chat with a retro terminal UI
- Backed by a persistent Claude Code session (survives open/close)
- Shows tool calls in real time as Claude works
- Runs as a background accessory app (no Dock icon)

## Requirements

- macOS 13+
- Xcode 15+
- [Claude Code CLI](https://claude.ai/code) installed at one of:
  - `~/.local/bin/claude`
  - `~/.npm-global/bin/claude`
  - `/opt/homebrew/bin/claude`
  - `/usr/local/bin/claude`
  - `/usr/bin/claude`

## Usage

1. Clone the repo and open `agentrocky.xcodeproj` in Xcode
2. Build and run (`Cmd+R`)
3. Rocky appears above your Dock — click him to chat

The chat session uses your home directory as the working directory, so Claude can run commands and tools relative to `~`.

## Architecture

| File | Purpose |
|------|---------|
| `agentrockyApp.swift` | App entry point, walk animation loop (60fps position, 6fps sprite) |
| `RockyState.swift` | Shared observable state (position, direction, chat open/closed) |
| `ClaudeSession.swift` | Manages the `claude` subprocess over stdin/stdout using stream-JSON |
| `RockyView.swift` | Sprite rendering and popover trigger |
| `ChatView.swift` | Terminal-style chat UI with scrolling output |
