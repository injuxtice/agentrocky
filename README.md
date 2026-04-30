# agentrocky

A macOS desktop companion app that puts an animated pixel-art Rocky on your screen, powered by the Gemini API.

Rocky walks back and forth along the top of your Dock. Click him to open a cozy chat window, paste a Gemini API key once, and chat with Rocky from your desktop. He can optionally speak replies with Gemini TTS.

## Features

- **Animated sprite** - Rocky walks across the bottom of your screen with smooth 60fps motion and 8fps sprite animation
- **Companion chat** - click Rocky to open a chat popover with friendly message bubbles
- **Gemini API support** - chat uses `gemini-3-flash-preview` through the Gemini Interactions API
- **Optional voice** - Gemini TTS uses `gemini-3.1-flash-tts-preview`, off by default, with a small voice picker
- **Keychain storage** - the Gemini API key is stored locally in macOS Keychain
- **Jazz celebrations** - Rocky dances when a reply finishes, and spontaneously jazzes out every 15-45 seconds while idle
- **Background accessory** - runs without a Dock icon, floating above all windows on every Space

## Requirements

- macOS 13+
- Xcode 15+ to build locally
- A Gemini API key from Google AI Studio

## Quick Start

```bash
git clone https://github.com/snehas/agentrocky.git
cd agentrocky
open agentrocky.xcodeproj
```

Press `Cmd+R` in Xcode to build and run. Rocky appears above your Dock. Click him, paste a Gemini API key, and send a message.

## Discord Build

This repo includes a script that creates a zipped Release app for private Discord sharing:

```bash
./scripts/package-discord.sh
```

The zip is written to:

```text
.build/discord/agentrocky-discord.zip
```

If `xcodebuild` says full Xcode is not selected, install Xcode and run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The generated app is ad-hoc signed for private sharing, not notarized. After unzipping, macOS may require the recipient to Control-click `agentrocky.app`, choose Open, then choose Open again.

## Sprite States

| State | Frames | Trigger |
|-------|--------|---------|
| Standing | `stand.png` | Chat window is open |
| Walking | `walkleft1.png`, `walkleft2.png` | Default movement, bouncing at screen edges |
| Jazz | `jazz1.png`, `jazz2.png`, `jazz3.png` | Reply complete or random idle celebration |

## Architecture

| File | Purpose |
|------|---------|
| `agentrockyApp.swift` | App entry point; 60fps walk loop, 8fps sprite animation, jazz trigger logic |
| `RockyState.swift` | Shared observable state: position, direction, chat visibility, speech bubbles, chat session |
| `GeminiChatSession.swift` | Chat state, Keychain coordination, Gemini request lifecycle, optional TTS playback |
| `GeminiAPIClient.swift` | Native REST calls for Gemini Interactions and Gemini TTS |
| `KeychainStore.swift` | Local Gemini API key storage |
| `RockyView.swift` | Sprite rendering, popover attachment, speech bubble overlay |
| `ChatView.swift` | Companion chat UI, first-run key entry, voice controls |
