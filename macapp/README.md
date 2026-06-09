# Ownscribe menu-bar app (macOS)

A small SwiftUI menu-bar front-end for [ownscribe](../). It drives the existing
`ownscribe` CLI — recording, transcription, summarization, config, and speaker
naming all go through the CLI, so `~/.config/ownscribe/config.toml` stays the
single source of truth and the app never reimplements pipeline logic.

## Requirements

- macOS 14.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonyz/XcodeGen) — `brew install xcodegen`
- A from-source ownscribe install in the repo (`uv sync` at the repo root, so
  `.venv/bin/ownscribe` exists).

## Build & run

```bash
cd macapp
xcodegen generate          # writes Ownscribe.xcodeproj from project.yml
open Ownscribe.xcodeproj    # then press ⌘R in Xcode
```

On first launch the app asks for your **ownscribe project folder** — pick the
repo root (the folder containing `.venv/bin/ownscribe`). It's remembered after
that.

## Permissions (one-time)

The app records audio on your behalf, so macOS attributes two TCC permissions to
it (not to your terminal):

1. **Screen Recording** — required to capture system audio. Grant it under
   *System Settings → Privacy & Security → Screen Recording*, then relaunch.
2. **Microphone** — only if you use *System + Mic*. macOS prompts on first use.

If a recording produces silence or fails immediately, it's almost always a
missing Screen Recording grant for the app.

## How it works

- **Quick bar** (per-run): capture source, Whisper model, language, template,
  and — when diarization is enabled — speaker count. These are passed as CLI
  flags for that recording only; they don't rewrite config.
- **Settings** (defaults, rarely changed): backend/model/host/API key, HF token,
  diarization, output folder. Each control writes via `ownscribe config set`.
- **Recording**: launches the full `ownscribe` pipeline; **Stop** sends `SIGINT`,
  which stops recording and lets it continue to transcribe + summarize.
- **Speaker naming** (after a diarized meeting): names the detected
  `SPEAKER_xx` labels via `ownscribe rename-speakers` (transcript only).

## Project layout

```
macapp/
  project.yml                 XcodeGen spec (source of truth for the project)
  Resources/Info.plist        LSUIElement (menu-bar only) + mic usage string
  Resources/Ownscribe.entitlements
  Sources/
    OwnscribeApp.swift        @main: MenuBarExtra + Settings window
    AppState.swift            state machine + CLI orchestration
    Core/                     CommandRunner, OwnscribeCLI, ConfigModel, Meeting
    Views/                    MenuContent, QuickBar, Status, Summary,
                              SpeakerNaming, Recent, Setup, Settings
```

`Ownscribe.xcodeproj` is generated and git-ignored; regenerate it any time with
`xcodegen generate`.
