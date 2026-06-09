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

Two options — both produce the same app.

**A. No Xcode required (fastest):** builds a signed `.app` with `swiftc` alone.

```bash
./macapp/build-app.sh --run     # builds macapp/build/Ownscribe.app and opens it
```

**B. Xcode workflow:**

```bash
cd macapp
xcodegen generate          # brew install xcodegen first; writes Ownscribe.xcodeproj
open Ownscribe.xcodeproj    # then press ⌘R in Xcode
```

On first launch the app asks for your **ownscribe project folder** — pick the
repo root (the folder containing `.venv/bin/ownscribe`). It's remembered after
that.

## Permissions (one-time)

The app records audio on your behalf, so macOS attributes two TCC permissions to
it (not to your terminal). To make the grant attach to the **app** rather than to
the downloaded `ownscribe-audio` helper, the app primes both grants in-process
(via `AVCaptureDevice.requestAccess` and `CGRequestScreenCaptureAccess`) before
each recording:

1. **Screen Recording** — required to capture system audio. The first recording
   triggers the prompt; grant it under *System Settings → Privacy & Security →
   Screen Recording*, then relaunch the app.
2. **Microphone** — only if you use *System + Mic*. macOS prompts on first use.

If a recording produces silence or fails immediately, it's almost always a
missing Screen Recording grant for the app.

## Known limitations

- **TCC attribution across the process chain.** Capture is performed by a
  grandchild helper (`ownscribe-audio`) downloaded to `~/.local/share/ownscribe`.
  The app primes the grants so they attach to the app bundle and the child
  inherits them, but for fully robust, distributable behavior the helper should
  be bundled inside the `.app` and code-signed with the same Team ID. The
  unsigned, network-downloaded helper is also not signature/hash-verified
  (inherited from the CLI; out of scope for this UI).
- **Silence auto-stop is disabled for GUI recordings** (`--silence-timeout 0`):
  you control Stop, which avoids the UI showing "Recording" while the pipeline
  has already begun transcribing. The CLI still honors `silence_timeout`.
- **Quitting mid-recording** signals the pipeline to stop (releasing the mic /
  CoreAudio tap); transcription of whatever was captured then finishes headless.
- **Recent meeting resolution** after a recording uses the newest folder under
  the output directory (the pipeline renames its folder with a title slug).

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

```text
macapp/
  project.yml                 XcodeGen spec (source of truth for the project)
  Resources/Info.plist        LSUIElement (menu-bar only) + mic usage string
  Resources/Ownscribe.entitlements
  Sources/
    OwnscribeApp.swift        @main: MenuBarExtra + Settings window
    AppState.swift            state machine + CLI orchestration
    Core/                     CommandRunner, OwnscribeCLI, ConfigModel,
                              Meeting, Permissions
    Views/                    MenuContent, QuickBar, Status, Summary,
                              SpeakerNaming, Recent, Setup, Settings
```

`Ownscribe.xcodeproj` is generated and git-ignored; regenerate it any time with
`xcodegen generate`.
