# Ownscribe menu-bar app (macOS)

A small SwiftUI menu-bar front-end for [ownscribe](../). It drives the existing
`ownscribe` CLI — recording, transcription, summarization, config, and speaker
naming all go through the CLI, so `~/.config/ownscribe/config.toml` stays the
single source of truth and the app never reimplements pipeline logic.

## Requirements

- macOS 14.0+
- **Xcode 15+ — the full app, not just the Command Line Tools.** `build-app.sh`
  calls `swiftc` directly and needs no Xcode *project*, which long made the CLT
  enough. It no longer is: in the macOS 26+ SDK, SwiftUI's `@State` is a macro,
  macros are expanded by plugin executables, and those plugins ship with Xcode
  only. With the CLT alone the build fails on the first `@State` with
  `external macro implementation type 'SwiftUIMacros.StateMacro' could not be
  found`. Check with `xcode-select -p`: it must name an `Xcode.app`, not
  `/Library/Developer/CommandLineTools`.
  If installing Xcode isn't worth it, CI builds the bundle on every push to
  `main` — see "Building without Xcode" below.
- [XcodeGen](https://github.com/yonyz/XcodeGen) — `brew install xcodegen`
- A from-source ownscribe install in the repo (`uv sync` at the repo root, so
  `.venv/bin/ownscribe` exists).

## Launch at login

Settings › General has a **Launch at login** toggle. It uses `SMAppService`, so the
app registers its own login item and appears under System Settings › General ›
Login Items & Extensions as the app itself.

This replaces dragging the bundle into Login Items by hand. A hand-added entry is
keyed to the bundle's path and signature, which is why it did not survive the
macOS 27 upgrade — the app had no way to notice or repair it. Two conditions for
it to stick:

- Run the app from `/Applications`. Registering from a build directory records
  that path, and the entry breaks the moment the app is moved.
- Sign with the local certificate (`make-signing-cert.sh`). An ad-hoc signature
  gives the bundle no stable identity, so the registration can be dropped again on
  the next upgrade.

macOS may show the login item as pending approval the first time; the toggle links
straight to the right pane.

## Side-by-side builds (keeping a fallback)

`build-app.sh --variant NAME` builds a second app that coexists with the installed
one, so a known-good build can be kept while a new one is tried:

```bash
bash macapp/build-app.sh --variant Next     # -> build/Ownscribe Next.app
bash macapp/build-app.sh                    # -> build/Ownscribe.app (stable)
```

Three things differ, and all three are needed for the two to be genuinely
independent:

| | stable | `--variant Next` |
|---|---|---|
| app | `Ownscribe.app` | `Ownscribe Next.app` |
| bundle id | `dev.p4l.ownscribe.menubar` | `dev.p4l.ownscribe.menubar.next` |
| managed env | `~/Library/Application Support/Ownscribe` | `~/Library/Application Support/Ownscribe Next` |

The separate bundle id matters because macOS keys Screen Recording and Microphone
grants off it — two bundles sharing an id fight over the same TCC record. The
separate managed env matters because the variant installs its own ownscribe;
sharing one would upgrade the stable app's environment too, so a bad CLI change
would break the very build being kept as a fallback.

**Models are not downloaded again.** Nothing model-related lives in the venv:
Whisper, the alignment models, pyannote and the summarization GGUF all resolve
through the HuggingFace cache (`~/.cache/huggingface`), the audio helper lives in
`~/.local/share/ownscribe/bin`, and config and recordings are shared. Only Python
packages are per-environment, and `uv` hardlinks those from its own cache
(`~/.cache/uv`) when the venv is on the same filesystem, so a second environment
costs far less disk than a full copy of torch.

To promote a variant to stable: rebuild without `--variant`, and delete
`~/Library/Application Support/Ownscribe Next` when you no longer need it.

### Trying an unreleased CLI in a variant

A variant installs the CLI from the release tag in `OwnscribeCLI.macappRelease`,
like the stable app. To try a CLI change before its tag exists, point the
variant's `OWNSCRIBE_CLI_SPEC` default at any pip requirement, such as your
checkout. `-string` is required: without it `defaults` tries to parse the
brackets and refuses the value.

```bash
defaults write dev.p4l.ownscribe.menubar.next OWNSCRIBE_CLI_SPEC -string "ownscribe[all] @ file://$PWD"
```

The variant reinstalls ownscribe from that spec the next time it starts, and
records the spec it installed. Delete the key to go back to the tag; the next
start then upgrades normally. The stable build ignores the key.

```bash
defaults delete dev.p4l.ownscribe.menubar.next OWNSCRIBE_CLI_SPEC
```

## Build & run

Two options — both produce the same app.

**A. No Xcode *project* required (fastest):** builds a signed `.app` with `swiftc`
alone. Xcode itself still has to be installed — see Requirements.

```bash
./macapp/build-app.sh --run     # builds macapp/build/Ownscribe.app and opens it
```

> The app is **ad-hoc signed** by default, so macOS resets its Screen Recording /
> Microphone grants on every rebuild. To keep the grants across rebuilds, create a
> stable local signing identity once — `build-app.sh` then uses it automatically:
>
> ```bash
> ./macapp/make-signing-cert.sh
> ```

**B. Xcode workflow:**

```bash
cd macapp
xcodegen generate          # brew install xcodegen first; writes Ownscribe.xcodeproj
open Ownscribe.xcodeproj    # then press ⌘R in Xcode
```

On first launch the app asks for your **ownscribe project folder** — pick the
repo root (the folder containing `.venv/bin/ownscribe`). It's remembered after
that.

### Building without Xcode

CI builds the bundle on every push to `main` and on every pull request, so a
machine with only the Command Line Tools can still get a runnable app.

1. Open the CI run on GitHub → **Actions** → the `macapp (macos-latest)` job →
   **Artifacts** → download `Ownscribe-app-macos-latest`.
2. Unpack and install it:

   ```bash
   tar xzf Ownscribe-app.tar.gz
   codesign --force --sign "Ownscribe Local Signing" \
     --entitlements macapp/Resources/Ownscribe.entitlements Ownscribe.app
   rm -rf /Applications/Ownscribe.app
   cp -R Ownscribe.app /Applications/
   ```

The re-signing step matters. CI has no access to your local signing identity, so
it signs ad-hoc; an ad-hoc bundle gets fresh Screen Recording and Microphone
prompts on every install and gives `SMAppService` no stable identity to attach a
login item to. `codesign` ships with the Command Line Tools, so this works
without Xcode. Create the identity once with `./macapp/make-signing-cert.sh`.

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

> **Persistent grants:** with ad-hoc signing the grant resets on every rebuild. Run
> `./macapp/make-signing-cert.sh` once for a stable signing identity; after switching
> you re-grant Screen Recording a single time, then it sticks across rebuilds.

## Known limitations

- **TCC attribution across the process chain.** Capture is performed by a
  grandchild helper (`ownscribe-audio`) downloaded to `~/.local/share/ownscribe`.
  The app primes the grants so they attach to the app bundle and the child
  inherits them, but for fully robust, distributable behavior the helper should
  be bundled inside the `.app` and code-signed with the same Team ID. The
  unsigned, network-downloaded helper is also not signature/hash-verified
  (inherited from the CLI; out of scope for this UI).
- **Silence auto-stop follows your Settings value.** It used to be forced to
  `--silence-timeout 0` because the app could not tell when capture ended; it now
  watches the CLI's `recording_stopped` event, so the preference is honoured.
  Note the helper decides "silence" by RMS — a downloaded (upstream) binary still
  uses peak and will not auto-stop in a normal room. Historical note:
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
  build-app.sh                no-Xcode build (swiftc + codesign)
  make-signing-cert.sh        one-time stable signing identity (persistent TCC grants)
  Resources/Info.plist        LSUIElement (menu-bar only) + mic & screen-recording strings
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
