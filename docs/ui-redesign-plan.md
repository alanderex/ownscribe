# Ownscribe: UI redesign + drag-and-drop import + parallel processing (plan v2.2)

Status: 2026-11-21. v2.2. Three review rounds (Swift engineer, Python engineer, architect, UI designer): round 1 produced v2; round 2 returned approve-with-conditions from all four; round 3 (confirmation of v2.1) did the same with narrower, implementation-level points. All conditions are folded in below. Final check: the Swift engineer, Python engineer, architect and UI designer each approved this text without conditions (a contradiction the UI designer found on `busy: unknown` in Library and the inspector was fixed first, and all four confirmed the fix). Execution is in Claude Code on the Mac.

Start: Phase 0 (baseline tag), then Phase 1 on branch `ui/phase-1-window-shell`.

## What changed after review

**Approved by the owner (round 1)**
- No `record` split. One `ownscribe` process per meeting, a global lock around the processing stage, a per-folder lock. Reason: with the mic on, a crashed app leaves unmerged `recording.wav.sys.tmp.wav` and `.mic.tmp.wav`, and an app-side queue is lost on quit or crash.
- No per-turn speaker reassignment. Markdown transcripts have no turn ids, and a moved turn leaves the summary stale. Rename and merge of speaker labels stay.

**Round 1, also in force**
- v1 claims that were wrong: "a running job finishes headless as today" (quit sends SIGINT and processing dies; a closed pipe breaks the title rename and the `keep_recording=false` deletion), "`import --title`" (subcommands drop the group flag), "Stop returns to idle immediately" (track merge takes up to 30 s), "Not processed covers failed jobs", "an XCTest target" (no build path).
- No Swift `TranscriptParser`: Python `show --json` replaces it. `edit-speakers` replaces the rename changes. `--reinstall-package ownscribe` replaces `--reinstall`. Python changes ship with the phase that uses them. No backup tag.

**Round 2 (v2.1)**
- `show --json` as planned was wrong: `parse_transcript` gives `[mm:ss] text` continuation lines under a speaker header no speaker, and drops the duration. The parser is fixed first, and a batch `show --list` is added (one process for all rows).
- The release sequence pushed an immutable tag before CI had run, and a `macappRelease` bump committed before its tag exists breaks the app's install. Revised in "Git and releases".
- Folder identity: titled folders drop the time (`YYMMDD-title`), the folder is renamed after summarizing, and `Meeting.id` is the folder name. `recording_started{folder}` and `meeting_saved{folder}` move into Phase 1; the per-folder lock moves into Phase 2.
- Options are fixed when a process launches. "Editable while queued" is removed; queue position is a count, not an order.
- Priority: `taskpolicy -b` at launch would throttle the capture the gate protects. Processing is demoted in-process after `recorder.stop()`.
- Stdin-EOF stop is opt-in (stdin is `/dev/null` today). Lock probes use `fcntl` F_GETLK so a probe never acquires. Busy exit code 75.
- Every Design item now has a phase. If the capture-gap gate fails, v0.18.0 ships without parallel recording.
- Transcript-text search is not in the redesign (the field searches titles and summaries; no in-transcript find).

**Round 3 (v2.2)**
- A failed or deferred upgrade no longer stops recording: the app runs in a degraded mode on the old CLI.
- The development override is a `defaults` key (an environment variable is dropped by `open`), stamps what it installed, and is honoured only by variant builds.
- Locks: one file descriptor per lock (closing any second descriptor drops it), counters for re-entrancy, the pid written through that descriptor, cancel signals use F_GETLK's `l_pid`. The global lock lives next to `config.toml`, not in the output directory. Lock failures other than "held" warn and continue.
- Fallback mode (gate failed): a recording process holds the global lock from the start, so drops and retries wait for it.
- Completion takes no focus: attention dot and popover "Ready · Open" are Phase 1; grouped notifications are Phase 3.
- The Phase 1 window shows the active run's steps, Cancel and failure message; click-to-play and the no-audio message are in Phase 1.
- The inspector auto-opens on transcript, diarization and unnamed labels; a missing summary no longer blocks it.
- Legacy folder names (`YYYY-MM-DD_HHMM_slug`) are parsed. `busy` and the lock arrive in Phase 2; the `*.tmp.wav` skip arrives in Phase 1.
- `busy` is true / false / unknown, with `holder_pid`; unknown folders stay out of Not processed but stay in Library and editable (a volume without lock support has only unknown folders). In fallback mode (gate failed) recordings set `OWNSCRIBE_EXCLUSIVE_RECORDING=1`, and exit 75 maps to a visible message. Restore covers the files that have an `.orig`. Notifications are one thread.

## Current state (verified in code)

- The whole UI is a 340 pt `MenuBarExtra` popover (420 pt scroll area). Settings is a fixed 560×480 window. `LSUIElement` is true: no Dock icon, no app window.
- Speaker naming (`SpeakerNamingView`) is one text field per `SPEAKER_xx` label. No transcript context, no audio, no merge, no undo.
- `rename-speakers` rewrites only `transcript.md`/`.json`. The summarizer is fed `speaker_text`, which contains the labels, so a summary can still say "SPEAKER_00" after renaming.
- `AppState` holds one global phase and one current meeting: one pipeline at a time, no queue. Recents are capped at 8. The app finds a finished meeting via `MeetingLoader.mostRecent` (newest folder). `Meeting.id` is the folder name; `Meeting.date` is the folder mtime; `MeetingLoader.load` runs on the main actor. 15 `@EnvironmentObject` sites and `extension AppState` bindings in `SettingsView` depend on `AppState`.
- Recording and transcription run in one process (`run_pipeline`). `recording_stopped` is emitted after `recorder.stop()`, which waits up to 30 s for track merging (`coreaudio.py:23`).
- Quit: `willTerminate` sends SIGINT to the running process (`AppState.swift:84-92`); `pipeline.py:408` restores the default handler after capture. The app pipes the child's stdout and stderr and sets stdin to the null device (`CommandRunner.swift:100`).
- Folder names: `YYMMDD-HHMM` for untitled runs; a titled run is `YYMMDD-title` (the time is dropped, `_titled_names`), renamed after summarizing. A third same-second untitled run reuses the first's directory (`exist_ok=True`, `pipeline.py:118-123`).
- `parse_transcript` (markdown.py:85-87) gives continuation lines `[mm:ss] text` under a speaker header no speaker, and discards the `**Duration:**` line. A resume of a diarized markdown transcript feeds the summarizer "Unknown:" for those lines.
- `output.audio_dir` can put audio outside the meeting folder (`config.py:56,111-125`, `pipeline.py:126-130`). `ownscribe resume` summarizes a transcript without a summary even when summarization is disabled (`pipeline.py:828`); `run_summarize` is a separate function from `_do_transcribe_and_summarize`.
- After a crash, `_find_audio` would pick `recording.wav.mic.tmp.wav` (sorted first, `.wav` is in `_MEDIA_EXTENSIONS`): a mic-only transcript.
- `ownscribe transcribe FILE` writes `transcript.md` next to the input (overwriting) and skips the summary. With `keep_recording=false` it also deletes the user's input file. Default is true.
- `title` is a local variable in `cli()`, used only without a subcommand (`cli.py:144`). `resume` tests `if language:` (`cli.py:278`), so `--language ""` is dropped there.
- The app installs the CLI from `git+https://github.com/alanderex/ownscribe@<macappRelease tag>` and `needsUpgrade` is an inequality test on the stamp, so an older or newer CLI both reinstall.
- Build: `build-app.sh` compiles all `Sources/**/*.swift` in one `swiftc` call; `project.yml` has one app target; there is no `Package.swift`; `.gitignore` has `build/` and `swift/.build/`, not `macapp/.build/`. CI runs on push and pull request to `main` only: lint (`ruff check`, `ruff format --check`, `mypy src/`), test, and the `macapp` job on macos-14 and macos-latest. `Info.plist` exists as `Resources/Info.plist` and as a heredoc in `build-app.sh`; the drift guard compares only `NS*UsageDescription` keys.
- Media the CLI accepts: wav, mp3, m4a, flac, ogg, webm, mp4, m4v, mov, mkv (`_MEDIA_EXTENSIONS`).
- App version is 0.15.4, not tagged: the latest tag is `macapp-v0.15.3` and `main` (`99e220e`) is 4 commits past it. The owner's Mac runs a macOS 26+ SDK era system (README), so macOS 14 behavior cannot be observed locally.

## Design

Menu bar = recorder. Window = workspace.

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ● ○ ○   [⏺ Record ▾]  [⬇ Import]            🔍 Search         [▯ Inspector]│
├──────────────┬────────────────────────────────────────┬───────────────────┤
│ IN PROGRESS  │  Q2 Sales Review                       │ SPEAKERS          │
│ ● Recording  │  Nov 18 · 42:10 · en · 3 speakers      │ ● Anna      ~38% ▶│
│   00:12:40   │  [ Summary | Transcript ]              │ ● Ben       ~45% ▶│
│ ▸ call.m4a   │  ┃ Anna  00:00                         │ ● SPEAKER_02 ~17% ▶│
│   Transcr 62%│  ┃ So the deadline for Q1…             │   Same person as… ▾│
│ ◌ Standup    │  ┃ Ben   00:21                         │ [Restore original  │
│   Queued · 1 │  ┃ They will hear from us by Friday.   │  names]            │
│ NOT PROCESSED│                                        │                   │
│ LIBRARY      │                                        │                   │
│ Today        │                                        │                   │
│  Q2 Sales…   │                                        │                   │
└──────────────┴────────────────────────────────────────┴───────────────────┘
```

Which part lands in which release: see "Scope by phase". The wireframe is the end state.

**Window.** `NavigationSplitView` (sidebar / detail) plus inspector. Default 1100×720, minimum 760×520, frame and sidebar state persisted. Activation policy is `.regular` while a window is open and `.accessory` otherwise. Sequence to open: `.regular`, wait about 100 ms, `activate(ignoringOtherApps: true)`, then `openWindow`. Return to `.accessory` asynchronously after `willClose`, only when no window other than the status item and the MenuBarExtra panel remains (Settings counts as open). The main window must not open at launch: on macOS 15+ use `.defaultLaunchBehavior(.suppressed)` (guarded by `#available(macOS 15)` and `#if compiler(>=6.0)`, so an older Xcode on the macos-14 runner still builds); on macOS 14 close it in the app delegate at launch. The macOS 14 path is untested (see Unverified).

**Recorder in the window.** The toolbar Record button becomes a red "Stop 12:40" while recording. Its ▾ opens the options form (title, capture, model, language, template, speakers; one view shared with the popover) only while idle: options are fixed when a recording starts. The button reads "Stop Recording" (not "Stop & Transcribe"); after Stop the recorder shows "Finalizing…" until `recording_stopped`. A recording or job row in "In progress" opens its step checklist in the detail pane, with Cancel; a failed run shows its error message there.

**Sidebar.** Groups: In progress, Not processed, Library (by day). Row: title, time, duration, speaker-count badge. Context menu: Reveal in Finder, Copy summary, Move to Trash. Replaces the 8-item Recents. Completion never changes the selection: the row gets a badge, cleared when that meeting is opened; the meeting opens by itself only when nothing is selected. Rows come from one process: `ownscribe show --list --json`.

**Library data.** Sort key: the day from the folder name (`YYMMDD-…`; the legacy `YYYY-MM-DD_HHMM_slug` is parsed too, and a name with no date falls back to the creation date), then the folder creation date within a day; row time is the creation date when it falls on that day, otherwise omitted (titled folders have no time in the name, and mtime changes on every edit). Load and index off the main actor. FSEvents plus a rescan on app activation. Search: a toolbar field that filters the Library by title and summary (case-insensitive substring); ⌘F focuses it. In-transcript find and transcript-text search are not in the redesign; "Copy transcript" covers whole-transcript copy.

**Folder identity.** The app keys meetings by folder path. `recording_started{folder}` tells it which folder a job owns; while the job runs that folder is shown under In progress and left out of Library. `meeting_saved{folder}` carries the final path after the title rename; the app maps job folder to final folder, updates the selection and any open draft, and then lists the meeting in Library. From Phase 2 on, `busy: true` in `show --list` (a held folder lock) is added to the job-owned test, which stays for the app's own jobs, so headless jobs from an earlier session are excluded too. `busy: unknown` (no lock support on the volume) does not hide a folder from Library: on such a volume every folder is unknown, so only the job-owned test applies there. A path that returns ENOENT is re-resolved, never treated as unlocked.

**Detail.** Header (title, date, duration, language, speaker count) and a Summary / Transcript switch. Summary uses the existing `RenderedMarkdown`, line length capped at ~720 pt, larger type. Transcript shows turns with a colored speaker bar, name and timestamp. Turns are keyboard-focusable with a VoiceOver action. Clicking a turn plays from there when audio is playable. Playback is offered only for extensions AVFoundation plays (wav, mp3, m4a, flac, mp4, m4v, mov; flac unverified); for other formats the transcript header says "Playback not available for .ogg". When no recording is kept (`show` reports no audio, for example `keep_recording` off) it says "No recording kept · playback unavailable" and turns do not play. Audio is located by `show`, which resolves `output.audio_dir`; the app does not look in the meeting folder itself.

**Speaker editor (inspector, Phase 2).** It opens automatically for diarized meetings with a transcript and at least one unnamed label whose folder is neither `busy: true` nor owned by a running job of the app; for such a folder it is read-only with "Processing…". A folder with `busy: unknown` stays editable (on a volume without lock support nothing could be edited otherwise); a headless job from an earlier session on such a volume is not detected. A missing summary does not matter: `edit-speakers` patches whichever files exist.
- Per speaker: stable color, name field (autocomplete from names used before), turn count, approximate talk-time share (start-to-next-start; markdown has no end times), ▶ sample, "Same person as…".
- Selecting a speaker highlights their turns and scrolls to the first. The sample is the speaker's longest turn (8 s at most) and plays when the name field gains focus. Without playable audio ▶ is hidden and the inspector says why (no recording kept, or an unsupported format).
- Tab follows row order; Return commits and moves to the next row; ⌘↩ saves and stays. Typing one name on two labels merges them, stated inline.
- Drafts: the transcript previews names live. Leaving the meeting saves the draft; Esc discards it. After saving, the button reads "Restore original names" and restores every file that has an `.orig` copy (the CLI keeps a one-time `.orig` of the transcript, and of the summary if one exists when names are first saved). A summary written after naming (a later Retry) keeps the new names, and the inspector says so.
- Until Phase 2 the existing `SpeakerNamingView` form sits in the detail pane.
- A turn assigned to the wrong speaker cannot be corrected in this plan; only whole labels can be renamed or merged.

**Popover.** Status, Start/Stop, timer, collapsed Options, "Open Ownscribe", last 5 meetings, and (Phase 1) the existing installing / permission-failure / failed-run / running-with-Cancel states. After a run finishes it shows "Ready · Open". Summary and speaker naming leave the popover. Menu-bar icon priority: recording, processing, idle.

**Signals and first run.**
- Phase 1: when a run finishes nothing takes focus: the menu-bar icon shows an attention dot (cleared when the meeting is opened in the window or popover), the popover shows "Ready · Open", and an open window badges the row (or selects the meeting if nothing is selected).
- Phase 3: finished jobs post notifications in one thread. A single job reads "Q2 Sales Review ready · 3 speakers to name" and opens the meeting; a batch collapses to "3 meetings ready". A VoiceOver announcement accompanies each.
- First run keeps the existing install and permission views (full-pane in the window) through Phase 2; Phase 3 replaces them with one checklist (Engine / Screen Recording / Microphone) with download progress, "Open System Settings" and "Quit & Reopen"; Record and Import are disabled with the reason shown.
- Empty library: a Record button (Phase 1); "Drop audio files here · ⌘O" is added in Phase 3.

**Keyboard and accessibility.** Menu commands: Record/Stop (Phase 1), Show Inspector ⌥⌘I (Phase 2), Import ⌘O (Phase 3). Reduce Motion is honored for `.symbolEffect(.pulse)` and the drop overlay. Speaker color is never the only identifier. Settings stays a `Window(id:"settings")`; ⌘, via `CommandGroup(replacing: .appSettings)`.

**Observation.** `@Observable` (macOS 14) for `Engine`, `Recorder`, `Library`, `Jobs`; views that bind use `@Bindable`. Nested `ObservableObject`s would not republish into the `MenuBarExtra` label. `elapsed` and step progress are read only by leaf views so the window does not re-render every second.

## Scope by phase

| Item | Phase 1 (0.16.0) | Phase 2 (0.17.0) | Phase 3 (0.18.0) |
|---|---|---|---|
| Window, sidebar (In progress with the single active run, its step checklist, Cancel and failure message; Library), search, Summary/Transcript, click-to-play, Copy transcript, context menu | yes | | |
| Window recorder, Stop/Finalizing, slim popover with existing status states, "Ready · Open", attention dot, row badge | yes | | |
| Degraded mode on the old CLI (failed or deferred upgrade): Record works, plain folder list, no transcript view or speaker editor | yes | | |
| Empty library with Record button, Settings window + ⌘, | yes | | |
| `show` / `show --list`, parser fix, `recording_started{folder}`, `meeting_saved`, `*.tmp.wav` skip in `_find_audio` | yes | | |
| Existing `SpeakerNamingView` in the detail pane | yes | replaced | |
| Inspector, speaker editor, drafts, merge, Restore, sample playback, ⌥⌘I, `edit-speakers`, per-folder lock, `busy` in `show --list` | | yes | |
| Queue with several rows, "Queued · N waiting", Cancel on queued rows, step checklist for every row | | | yes |
| Not processed, Incomplete recording row, failed rows with Retry / Show Log, orphan "Processing" rows | | | yes |
| Notifications, VoiceOver announcement, quit confirmation | | | yes |
| Import: window/sidebar/Dock drop, ⌘O, toolbar Import, unsupported-file banner, document types | | | yes |
| First-run checklist, empty-library drop hint | | | yes |
| Parallel recording (gate) | | | yes, if the gate passes |

## Parallel processing (record the next meeting while the previous one transcribes)

- **Process model.** One `ownscribe` process per meeting, as today. Recorder: `.recording` → Stop → `.finalizing` → idle on `recording_stopped`. At idle a new recording may start while the previous process transcribes (Phase 3).
- **Locks** (helper module with tests, Python). POSIX record locks via `fcntl`, so a probe uses F_GETLK and never acquires (a `flock` probe would make a concurrent non-blocking take fail with a spurious "busy").
  - Per-folder `<folder>/.ownscribe.lock`: taken non-blocking, exclusive, right after the folder is claimed (before `recorder.start`) and at the start of `resume` and `edit-speakers` (and `import` once it exists in Phase 3). Held → exit 75 (EX_TEMPFAIL); a process that already claimed a folder removes that empty folder before exiting. The holder writes `{pid, kind, folder}` through its lock descriptor, for display and for the fallback busy test only; it is never used to choose a process to signal.
  - Global `processing.lock` in the directory that holds `config.toml` (local and stable, so a stable app and a variant, which use different venvs, still serialize; the output directory may be on iCloud or a NAS): blocking, around the processing stage of `_do_transcribe_and_summarize`, `run_summarize` and import. One re-entrant `processing_lock()` context manager in the process. Order is always folder, then global.
  - The lock file is ignored by the empty-folder cleanup (`pipeline.py:159`). A terminal user waiting on the global lock sees one line.
  - Each lock is one open file descriptor per process, kept for the lifetime of the lock. Closing any other descriptor on the file drops a POSIX lock, so a second `open` of the lock file, `Path.write_text` or a temp-and-replace write on it is forbidden. Re-entrancy (both locks) is a counter on that descriptor; the metadata is written through it (truncate and write). Tests use separate processes; thread tests prove nothing here, because threads do not exclude each other.
  - A lock failure other than "held" (no lock support on the volume, an unwritable directory) prints a warning and continues unlocked; `show --list` then reports that folder as `busy: unknown`, and the Not processed rule excludes unknown folders as well as busy ones. Library and the inspector do not treat unknown as busy (see Folder identity and Speaker editor).
  - A rename of a locked folder keeps the lock (it follows the inode); the old path then returns ENOENT.
  - Whether F_GETLK probing behaves as described is verified by a test in the phase that adds the lock; if it does not, the probe falls back to pid liveness for deciding busy only (never for choosing whom to signal). That fallback has no `l_pid`, so an orphan's row has no Cancel.
- **Serial processing.** A waiting process emits `queued` (no position) and starts when the lock frees, not in arrival order. The sidebar shows "Queued · N waiting". One Whisper model resident.
- **Cancel.** SIGTERM to a waiting process (the app's own child pid, or `l_pid` from F_GETLK for an orphan). A recording's WAV stays (the folder shows under Not processed). An import handles SIGTERM before processing by removing its copied file and folder if nothing else is in them.
- **Options are fixed at launch.** Job argv is `ownscribe <group flags> <subcommand> ...`. Config values read at job start (`keep_recording`, format, summarization on/off) are passed as flags when they must be fixed. A queued row shows its options read-only; to change them, cancel and drop again.
- **Headless-safe.**
  - In events mode stdout and stderr are replaced at CLI start by tolerant writers that swallow BrokenPipeError and OSError, covering every `click.echo` (including `pipeline.py:380` and `coreaudio.py:361`).
  - Stdin control is opt-in: only when `OWNSCRIBE_STDIN_CONTROL=1`, which the app sets together with a stdin pipe. EOF then stops the recording gracefully (tracks merged) and processing continues headless. Without the variable stdin is untouched (cron, nohup, CI).
  - On quit the app signals only a recording; processing and queued processes keep running. Quit while recording asks first ("Recording in progress. Stop and process?").
- **Orphans.** After a relaunch a busy folder from an earlier session appears as a "Processing" row ("started by an earlier session"), cancellable by SIGTERM to the pid that F_GETLK reports (`l_pid`), never the pid written in the file, which can be stale; `show --list` carries it as `holder_pid`. Steps are unknown.
- **"Not processed"** comes from `show --list` status, evaluated on launch and on app activation: audio (found through `output.audio_dir`, ignoring `*.tmp.wav`) and no transcript; or a transcript whose summary is missing while summarization is enabled. Folders with `busy` true or unknown, and the active recording, are excluded. A folder with only `*.tmp.wav` tracks shows as "Incomplete recording" with Reveal in Finder only.
- **Events.** `recording_started{folder}` and `meeting_saved{folder, summary: ok|failed|unavailable|disabled}` (Phase 1; `meeting_saved` is the last event on every success path: full pipeline, `resume` including summarize-only and "nothing to resume"). `import_started{folder}` and `queued` (Phase 3). The app takes the final folder from the captured stderr at exit, since events and exit arrive on separate hops. `ProgressEvent` in `CommandRunner.swift` gains `folder` and `summary`. Unknown events are already ignored.
- **Atomic writes** (temp file plus `os.replace`) for transcript, summary, config set and speaker edits. `keep_recording=false` deletion also applies in the summarize-only branch. `_get_output_dir`'s final fallback takes a numeric suffix instead of reusing a directory (batch imports start in the same second).
- **Priority.** No launch-time wrapper for recording processes, because the audio helper inherits their priority. After `recorder.stop()` the process demotes itself (`os.setpriority(PRIO_PROCESS, 0, 10)`); import processes start demoted. The gate decides whether more is needed.
- **Gate before Phase 3 (needs the Mac and real audio; no new code).** With today's CLI, record 10+ minutes while a long file is transcribed with `large-v3` and diarization on. Compare the `.sys` and `.mic` track durations and the final WAV with wall-clock time. Contention is also on the GPU (diarization on MPS, llama.cpp on Metal versus ScreenCaptureKit), which a thread cap does not cover. If audio drops, decide the mitigation (a per-job thread cap flag or env var; `transcription.threads` exists only as global config). If there is none, v0.18.0 ships without parallel recording: recording stays blocked while a job runs, everything else in Phase 3 ships. In that mode the app sets `OWNSCRIBE_EXCLUSIVE_RECORDING=1` for recordings, and the recording process takes the global lock when capture starts (non-blocking; held → exit 75, after removing the empty folder it claimed). The app maps exit 75 on Record to "Another ownscribe job is still processing" and shows the busy row. A drop, ⌘O or Retry started during a recording queues behind it and shows "Queued · waits for the recording".
- **Install gate and degraded mode.** The app never reinstalls while any process runs from the managed venv, matched on the command line (`<venv>/bin/ownscribe` in argv, which also sees orphans; the venv's `bin/python` is a symlink, so the executable path is not reliable). When an upgrade fails, or is deferred because a job is still running, the app runs in degraded mode on the old CLI with the banner "Update failed · Retry" or "Update pending · waiting for running jobs". Record keeps working (as today), the Library is the plain folder list from the existing `MeetingLoader`, completion falls back to the newest folder, and the transcript view and speaker editor are off. A test with a bad ref confirms the old CLI is left runnable (unverified).

## Drag-and-drop import (Phase 3)

- **Targets:** the window (full-pane drop overlay), the sidebar, the Dock icon / app icon in Finder, ⌘O, the toolbar Import button. Not the popover: a `MenuBarExtra` panel dismisses when the user clicks Finder to start the drag.
- **Flow:** a drop starts the job at once with current defaults; the row shows "call.m4a · base · Auto" read-only with Cancel. ⌥-drop opens an options sheet first. Unsupported files get a non-modal banner naming them. The finished meeting appears in Library with a badge.
- **Opening via Dock/Finder:** `@NSApplicationDelegateAdaptor` with `application(_:open:)`, feeding a buffer created in `App.init` (`.onOpenURL` on a cold launch is unverified). `CFBundleDocumentTypes` lists only the supported extensions with `CFBundleTypeRole` Viewer and `LSHandlerRank` Alternate (no blanket `public.audio`/`public.movie`: that offers .aiff and .avi and then rejects them). The key is added to both plists and the drift guard is extended to compare it.
- **CLI `ownscribe import FILE`.** Claims the meeting folder and takes its lock, emits `import_started{folder}`, copies the file in (destination via `_get_output_audio_dir`) to `<name>.part`, renames it, then waits for the global lock and transcribes. `click.Path(dir_okay=False)` and a lowercase extension check against `_MEDIA_EXTENSIONS`; no abort on `_check_audio_silence`. The original path never reaches the shared transcribe code, because with `keep_recording=false` that code deletes its input. Takes the group flags; `--title` is plumbed through `ctx.obj`.

## Code structure

- `macapp/Package.swift`: `// swift-tools-version: 5.9`, `platforms: [.macOS(.v14)]` (as `swift/Package.swift` does; SwiftPM's default would let macOS 13+ APIs compile in the app and fail in `swift test`). A Foundation-only library target `Logic` over `macapp/Sources/Logic/` (extension validation, job and event state, folder-name parsing, the Library loader) plus an XCTest target in `macapp/Tests/LogicTests/`. `build-app.sh` already globs `Sources`, so the app compiles `Logic` in its single module and must not `import Logic`; tests use `@testable import Logic`. Code in `Logic` cannot depend on app types: `MeetingLoader.outputDir(_: OwnscribeConfig)` and `PipelineStep` stay in the app target or take plain parameters. CI adds `swift test --package-path macapp` on both macOS runners. `macapp/.build/` goes into `.gitignore`.
- Split `AppState` into four `@Observable` objects: `Engine` (config, CLI, install and bootstrap, permission-failure state, available models, quick-bar selections), `Recorder`, `Library`, `Jobs` (child processes and their states; scheduling is done by the locks). `SettingsView`, `QuickBarView` and `MenuContentView` migrate in Phase 1.
- New folders under `Views/`: `Library`, `Detail`, `Inspector`.

## Python changes (each ships with the phase that uses it)

- **Phase 1:**
  - Fix `parse_transcript`: continuation lines inherit the current speaker; a turn is a speaker run; the duration line is kept. Test on diarized markdown and JSON (this also removes "Unknown:" from resume summaries).
  - `ownscribe show DIR --json`: `schema`, turns (ordinal, speaker, start, text; end from JSON or next start), speakers (turn count, approximate seconds, longest turn), duration, language, title, status (transcript, summary: present|missing|disabled, audio path resolved through `output.audio_dir`, `.orig` present). Prefers `transcript.json` when both formats exist.
  - `ownscribe show --list --json`: one row per meeting folder (path, name day, creation date, title, duration, speaker count, status; from Phase 2 also `busy: true|false|unknown` and `holder_pid`) in one process. It must not import the transcription or summarization stacks; target under 300 ms for 200 folders, measured in a test; a (path, mtime) cache only if it is not.
  - `recording_started{folder}` and `meeting_saved{folder, summary}` events.
  - `_find_audio` skips `*.tmp.wav` (used by `show` and the Not processed rule).
- **Phase 2:**
  - Lock helper with the per-folder lock (see Parallel processing); `resume`, the pipeline and `edit-speakers` take it; busy exits 75; `show --list` gains `busy: true|false|unknown` and `holder_pid` (F_GETLK probe). Cross-process tests, including one-descriptor and re-entrancy cases.
  - `ownscribe edit-speakers DIR --map A=B ... [--revert]`: one regex pass with alternation sorted longest first, `(?<!\w)…(?!\w)` boundaries and a callable replacement (handles SPEAKER_1 vs SPEAKER_10, backslashes, `$`, swaps); patches transcript and summary, `.md` and `.json` when both exist (for `summary.json` it edits the `summary` value); atomic; one-time `.orig` copies of both files; rejects `*` in names; two labels mapped to one name merge; takes the folder lock.
- **Phase 3:**
  - Global lock, `queued`, `import_started`, `OWNSCRIBE_EXCLUSIVE_RECORDING` (fallback mode), tolerant writers, opt-in stdin control, demotion after `recorder.stop()`, `import`, numeric-suffix directory fallback, `--title` and `--language` plumbing for subcommands (`is not None` in `resume`), `import` takes the folder lock, atomic writes and `keep_recording` in the summarize-only branch, `FakeRecorder` moved to `conftest.py`.
- Every phase: tests in `tests/`, README sync for new commands (AGENTS.md requires it).
- **Swift, Phase 1:** `OwnscribeCLI.install` uses `--reinstall-package ownscribe`; a development override, the `defaults` key `OWNSCRIBE_CLI_SPEC` of a variant build (`defaults write <variant bundle id> OWNSCRIBE_CLI_SPEC <pip spec or path>`; an environment variable would not survive `open`, which `build-app.sh --run` uses), replaces the git spec. The stable build ignores it, and the install stamps the spec it actually installed, so removing the key triggers a normal upgrade. It lets an unreleased CLI be tried before its tag exists (noted in `macapp/README.md`).

## Phases

0. **Baseline.** Tag `99e220e` as `macapp-v0.15.4` (see Releases). The capture-gap test can run any time before Phase 3.
1. **Window shell + `show` + events.** Per "Scope by phase". Spike first: the main window must not open at launch (macOS 15+ `.defaultLaunchBehavior(.suppressed)`, macOS 14 fallback untested). Failed-upgrade test. Release `macapp-v0.16.0`, `macappRelease` = `macapp-v0.16.0`.
2. **Speaker editor + `edit-speakers` + folder lock.** Release `macapp-v0.17.0`.
3. **Parallel processing + import.** After the gate. Release `macapp-v0.18.0`.

Order is 1, 2, 3. Phase 3 needs the Phase 1 shell and the lock helper, so it may ship before Phase 2 only on the owner's say-so, in which case the lock helper, including the `busy` probe in `show --list`, ships with it and tags follow shipping order. Each phase ends buildable and usable.

## Git and releases

**Commits**
- Commit after every logical step, one change per commit, each leaving the tree building. Message style as in the repo log: `macapp: <imperative summary>` for Swift, plain imperative for Python.
- Gate before every commit: Python: `uv run ruff check src/ tests/`, `uv run ruff format --check src/ tests/`, `uv run mypy src/`, `uv run pytest -m "not hardware"`. Swift: `./macapp/build-app.sh` and `swift test --package-path macapp` once it exists.
- One branch per phase (`ui/phase-1-window-shell`, ...). The uncommitted `uv.lock` change predates this work and stays out; commits stage files by path.

**Releases**
- Every release is an annotated tag `macapp-vX.Y.Z` equal to the app version (`MARKETING_VERSION` in `project.yml`, `CFBundleShortVersionString` in `build-app.sh`). Tag message follows the existing ones: `macapp X.Y.Z on ownscribe <pyproject version>`, then what changed.
- Baseline: tag `99e220e` as `macapp-v0.15.4` before any work.
- Each of v0.16.0, v0.17.0 and v0.18.0 carries Python changes, so each bumps `macappRelease` to its own tag in the same commit as the version bump.
- Sequence for a release: version-bump commit on the phase branch → open a pull request to `main` (CI runs only on pushes and pull requests to `main`) → wait until lint, test and both `macapp` runners are green → tag the pull request's head commit → push only the tag and confirm it on `origin` → fast-forward `main` to that commit and push. The tag is on `origin` before any build that names it, and no tag is pushed before CI has passed. A development build runs an unreleased CLI through the `OWNSCRIBE_CLI_SPEC` defaults key.
- A pushed tag is never moved or deleted (`needsUpgrade` relies on it). A bad release is superseded by the next patch tag.
- Plain tags only, no GitHub Release: `publish.yml` (PyPI) and `build-binary.yml` (audio helper) trigger on `release: published`.
- Push only on the owner's say-so, each time.

## Unverified; settle by spike or test

- macOS 14: whether the main `Window` opens at launch and the fallback (the owner's Mac cannot show it; CI cannot observe windows).
- `MenuBarExtra` panel dismissal when Finder takes focus; `SettingsLink`/`openSettings` unreliability and `NSApp.activate()` for accessory apps; `.onOpenURL` on cold launch; `.textSelection` across `LazyVStack` rows; lazy creation of `MenuBarExtra` content (if so, `bootstrap` must also run from `App.init`).
- F_GETLK probing of `fcntl` locks as designed (a reviewer's Linux test passed; Darwin is unverified; test in Phase 2, with separate processes); the closed-pipe failure (reproduced by a reviewer with click 8.5.1, not by me); `os.setpriority` demotion being enough (the gate decides); a failed `--reinstall-package` leaving the old install runnable; AVFoundation playing flac; folder creation date surviving copies and restores (the name day is the fallback); `show --list` speed.

## Defaults assumed

- Dock icon only while a window is open.
- One processing job at a time; recording never blocked (if the gate passes).
- One branch per phase; `main` receives phases by fast-forward after the release sequence above.
- Not planned: per-turn speaker reassignment, in-transcript find, transcript-text search, an automatic recovery of `*.tmp.wav` recordings, a Dock "Always/Never" setting, theming, word-level transcript editing, export formats beyond Copy/Reveal, global hotkey, multi-window.
