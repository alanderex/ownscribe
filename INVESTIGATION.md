# Ownscribe — codebase investigation

Date: 2026-08-28 · Scope: `ownscribe` @ `78142df` (main) and `ownscribe-macui` @ `ad3fa79` (`feature/macos-menubar-ui`)

---

## ⚠️ Correction (same day, after fetching upstream)

The original investigation was written against **stale upstream refs** — `paberr/main` was cached at
`5a5d501`, but upstream is actually at `9d5f82e` (**v0.15.0**, released 2026-08-14). After fetching,
three claims below are wrong:

**1. "The MicCapture fix exists only on this laptop" — FALSE.**
`78142df` and upstream's `b65d23a` are the *identical patch* (same patch-id `e7861f9d82d0`), both
authored by Davide Morelli. It was a PR that landed in both places; upstream merged it 6 days after
this fork. Upstream has since *improved* it (`f2383c0`, throttled write-error logging). Nothing was
at risk of being lost. §2a and §2c below overstate this badly.

**2. Several P0/P1 bugs listed below are already fixed upstream:**

| Finding below | Upstream fix |
|---|---|
| P0 #2 `--no-mic` defeated by `mic_device` | `04748d2` Honor an explicit mic = false when a mic device is configured |
| P0 #3 `summary.json` contains markdown | `bec3777` Write real JSON to summary.json |
| P1 no transcript chunking in `summarize()` | `ff82ada` Chunk long transcripts instead of overflowing the context window |
| P1 directory rename can clobber | `185c9f9` + `30735ee` Guard the rename collision check |
| "two different inputs feed the same summarizer" | `195ca82` Normalise saved transcripts before summarizing |
| P9 unbounded dependency ranges | `04fbff0` Pin torchaudio below 2.9 |

**3. This fork is 30 commits behind upstream and 16 ahead.** Of those 16, four (`d01adf9`,
`f67ab91`, `d1e9b73`, `78142df`) are *already upstream by patch-id*. The genuinely unique work is
the 11 `macapp/` commits and nothing else.

**Also established:** PyPI `ownscribe` is owned by `paberr` (sole maintainer, v0.15.0). This fork
cannot publish under that name, so the macapp installer must either pin a git tag on this fork or
the macapp must go upstream.

Read the sections below with those corrections applied. The architecture map (§3), the seam
analysis, the test/CI assessment (§4) and the macapp-specific findings remain accurate — they
describe this fork's code, which upstream doesn't have.

---

## 1. Why there are two repositories

**There aren't.** `ownscribe-macui` is a **git worktree** of `ownscribe`, not a separate repo:

```
$ cat ownscribe-macui/.git
gitdir: /Users/hendorf/code/modelserver/ownscribe/.git/worktrees/ownscribe-macui

$ git -C ownscribe worktree list
/Users/hendorf/code/modelserver/ownscribe        78142df [main]
/Users/hendorf/code/modelserver/ownscribe-macui  ad3fa79 [feature/macos-menubar-ui]
```

One repo, one `.git` (1.9 MB, healthy), two checkouts of two branches. The duplicated `src/`, `tests/`, `README.md`, `.venv/` are just the two branches' working trees — not forks.

Remotes: `origin` = `git@github.com:alanderex/ownscribe.git`, `paberr` = `https://github.com/paberr/ownscribe.git` (upstream you forked).

### Branch state

Merge base is `f67ab91`.

| | ahead of base | contains |
|---|---|---|
| `main` | 2 commits | `78142df` MicCapture route/format fix, `d1e9b73` video input |
| `feature/macos-menubar-ui` | 11 commits | the whole `macapp/` SwiftUI menu-bar app, `config get/set`, speaker naming, `--no-mic` |

Plus a **third, unversioned line of work**: ~600 lines of MLX transcription backend sitting uncommitted in `main`'s working tree.

---

## 2. The headline risk: three divergent copies, and the app runs none of them

This is the finding that matters most, and it explains why the app can feel flaky in real meetings.

### 2a. Your best audio fix exists in exactly one place — this laptop

`78142df` "MicCapture: survive input format/route changes (Meet, earbuds)" is:

- **not on the feature branch** — verified: `git diff --stat <merge-base> feature -- swift/` is *empty*, so the feature branch's `swift/` tree is byte-identical to the merge base. It never touched AudioCapture; main did.
- **not pushed** — `git log origin/main..main` returns exactly that one commit.

So the fix lives only in `/Users/hendorf/code/modelserver/ownscribe`. Not on GitHub, not on the branch the app is built from.

### 2b. What the fix actually does (and what the app is missing without it)

`main`'s `swift/Sources/AudioCapture.swift` adds, relative to the feature branch (+174/−26):

| | main | feature branch (what the app uses) |
|---|---|---|
| Mid-stream format change | Pins the file's `processingFormat`, runs every tap buffer through an `AVAudioConverter` (`:40-45`, `:184-223`) | Naive `audioFile?.write(from: buffer)` (`:121`) |
| Route change (earbuds) | Observes `.AVAudioEngineConfigurationChange`, rebinds device, reinstalls tap, retries 20× @ 0.25 s (`:109-113`, `:236-271`) | Nothing |
| `inputNode.audioUnit` nil during route flux | `guard let … else { throw }` (`:122-139`) | `input.audioUnit!` — force-unwrap crash (`:76`) |

Concretely: **when Google Meet / Zoom flips the shared input into voice-processing mode mid-call, every mic write fails with OSStatus −50 and the mic track is silently lost for the rest of the meeting.** The error only goes to stderr, which `coreaudio.py:154-170` swallows. That is the exact bug `78142df` was written to fix, and the app doesn't have it.

### 2c. The runtime chain is spliced from two different forks

The standalone menu-bar app assembles itself from two independently-versioned halves:

```
Python side  →  git+https://github.com/alanderex/ownscribe@feature/macos-menubar-ui
                (OwnscribeCLI.swift:26-27 — verified verbatim)

Swift helper →  https://github.com/paberr/ownscribe/releases/latest/download/ownscribe-audio-{arch}
                (coreaudio.py:30 — upstream's fork, currently at 5a5d501)
```

The wheel ships **no** helper binary (`pyproject.toml` has only `[project.scripts] ownscribe`), and for the app's managed venv at `~/Library/Application Support/Ownscribe/.venv`, the dev-path candidate `parents[3]/bin/ownscribe-audio` lands inside `.venv/lib/pythonX.Y/` — not a repo root. So resolution falls through to the download.

Result: the app installs *your* feature branch's Python and runs *upstream's* audio helper. Neither contains `78142df`. Your local `bin/ownscribe-audio` (194 KB, built Jun 17) is the good one, and it's untracked and reachable only from the `main` checkout.

Two further consequences:

- `pipSpec` pins a **moving branch**. The moment you merge and delete `feature/macos-menubar-ui`, first-run install breaks permanently for every new user. It also hardcodes `alanderex`, so it's wrong for upstream.
- `_download_binary` does `urllib.request.urlretrieve(url, dest)` then `chmod 0o755` (`coreaudio.py:44-49`) with **no checksum and no signature**, always from `latest` regardless of the installed Python version — while the Python↔Swift protocol is stringly-typed (`--capture-mode-all`, `[SILENCE_WARNING]` scraped from stderr). Version skew there fails silently.

### 2d. ~600 lines of finished work are untracked

```
 M README.md pyproject.toml config.py pipeline.py progress.py
   whisperx_transcriber.py test_progress.py test_transcription.py uv.lock   (242 ++/--)
?? src/ownscribe/transcription/mlx_transcriber.py   126
?? transcribe_dir.py                                129
?? tests/test_mlx_transcriber.py                     65
?? tests/test_transcribe_dir.py                      42
```

That's the **MLX Apple-Silicon GPU transcription backend** — with a `pyproject.toml` extra, a documented README section, and 8 tests — plus a batch directory-transcription tool. It's on no branch and CI has never seen it. One `git clean` from gone.

### 2e. You've already done the same work twice

`d1e9b73` (main) and `a319f3e` (feature) are both "Accept video files (mp4/mov/mkv) as transcription input" — the same change, authored ~2 seconds apart, developed independently on two branches. That's the cost of the split already being paid once.

---

## 3. Architecture map

### Python core (`src/ownscribe/`, ~3,700 LOC)

```
cli.py (click group, invoke_without_command)
  └─ run_pipeline (pipeline.py:169-271)
       ├─ _get_output_dir      → ~/ownscribe/YYYY-MM-DD_HHMM/recording.wav
       ├─ _create_recorder     → CoreAudioRecorder | SoundDeviceRecorder
       ├─ 2 Hz poll loop: clock, `m` = mute, Ctrl-C = stop (cbreak tty)
       └─ _do_transcribe_and_summarize (:410-522)   ← shared with transcribe/resume
            ├─ _create_transcriber  → WhisperX | MLX
            ├─ _format_output       → transcript.{md,json}
            ├─ create_summarizer    → llama_cpp | ollama | openai
            └─ rename dir → {timestamp}_{title-slug}
```

**Abstraction seams**, honestly rated:

| Seam | Quality |
|---|---|
| `Summarizer` ABC (`summarization/base.py`) | Clean 4-method contract. `chat()` is what `ownscribe ask` builds on. Best seam in the repo. |
| `_run_asr()` override (`whisperx_transcriber.py:223-235`) | Good, documented extension point — MLX is the worked example. Undermined by `self._model` holding a `Llama`-ish object in the parent and a bare `str` in the child (`mlx_transcriber.py:100`, commented as a "truthy sentinel"). |
| `AudioRecorder` ABC (`audio/base.py`) | **Leaky.** The pipeline needs `silence_timed_out` and `silence_warning`, neither on the ABC, both read via `getattr(recorder, ..., False)` (`pipeline.py:250`, `:267`). |
| `Transcriber` ABC | Clean, but nothing implements it directly — MLX subclasses the *concrete* WhisperX class, dragging torch/pyannote/ffmpeg along. |
| Output formatters | **Not a seam.** A hard `if config.output.format == "json"` in `_format_output` (`pipeline.py:137`). No ABC, no registry. |
| Progress | Duck-typed, no `Protocol`. `WhisperXTranscriber` type-hints `progress: NullProgress | None` — the *null* implementation as the type of the real one. |

**Config**: `~/.config/ownscribe/config.toml`, nested dataclasses. Defaults are written in **three** places (dataclass fields, `DEFAULT_CONFIG_TOML`, README) with nothing enforcing sync. `_merge_toml` (`config.py:145-179`) is five copy-pasted blocks with **no validation and no type coercion** — unknown keys are silently dropped (`hf_tokn` is a no-op) and `silence_timeout = "300"` survives load, then explodes at `divmod()`. No `--config` flag; tests monkeypatch a module global.

### Swift / macOS

- **`swift/Sources/AudioCapture.swift`** (1,078 L on main) — CLI helper `ownscribe-audio`. System audio via **ScreenCaptureKit** (24 kHz mono + a 2×2 px dummy video stream, since SCK requires one), mic via **AVAudioEngine** tap. The two tracks go to separate temp WAVs and are **merged offline** at shutdown using `mach_timebase_info` host-time alignment. Also holds an `IOPMAssertion` so display sleep can't kill the SCStream.
- **`macapp/`** (15 SwiftUI files, feature branch only) — `MenuBarExtra(.window)`, `AppState` as a `@MainActor` phase machine (`installing/idle/recording/processing/done/failed`).

**IPC contract**: `CommandRunner` spawns the venv console script as a `Process`, drains stdout/stderr into a buffer, and delivers everything **at exit**. Five commands: `config get` (JSON), `config set`, `list-speakers` (JSON), `rename-speakers`, and the bare pipeline invocation.

The Python side is unusually well-behaved for this — `config_io.py` emits real JSON with secrets redacted, and `config get` doesn't import torch. But the transport is **buffer-and-parse-at-exit**, which means:

- The pipeline's rich `PipelineProgress` TUI runs for the entire job, is captured, and is then **discarded**. The UI can only show an indeterminate spinner — no "transcribing 40%", no model-download progress, and unbounded memory growth over a long recording. *This is the single largest UX gap in the app.*
- Errors surface as `firstMeaningfulLine(stderr)` — for a torch/whisperx stack that's almost always an unrelated deprecation warning, not the real error.
- One stray `click.echo` on stdout in the config path breaks `JSONDecoder` and hard-fails the app to `.failed`.

---

## 4. Findings by severity

### P0 — data loss / privacy / silent wrong output

| # | Finding | Evidence |
|---|---|---|
| 1 | **MLX work exists only untracked on disk.** ~600 lines incl. tests and docs. | §2d |
| 2 | **`--no-mic` doesn't disable the mic** if `audio.mic_device` is ever set. The GUI's "System only" sends `--no-mic`, which sets `mic = False` but leaves `mic_device` — and `coreaudio.py:105` is `if self._mic or self._mic_device: cmd.append("--mic")`. | `coreaudio.py:105-108`, `AppState.swift:139` |
| 3 | **`summary.json` contains markdown, not JSON.** In the JSON branch `_format_output` returns `summary_text` **unchanged** (`pipeline.py:139`); there is no summary formatter in `json_output.py` (13 lines, one function). | verified |
| 4 | **`cleanup -y` deletes config + cache + your entire `~/ownscribe` output tree with no prompt.** With no target flags, the interactive branch is `if yes or click.confirm(...)` per directory, so `-y` auto-approves all three and never reaches the summary/confirm at `:301`. | `cli.py:284-299` |
| 5 | **Screen-recording denial is ignored.** `Permissions.prime()` discards the result of `ensureScreenRecording()`. `CGRequestScreenCaptureAccess()` returns `false` on first call and needs a relaunch — so the app records a silent WAV, exits 0, and hands you an empty transcript. `macapp/README.md:59` says this is "almost always" the cause of empty output. | `Permissions.swift:26-29` |
| 6 | **Unverified binary download** from `latest`, no checksum/signature, executed. | `coreaudio.py:44-49` |

### P1 — robustness

- **Undrained subprocess pipe.** `CoreAudioRecorder.start` opens `stdout=PIPE` and `stderr=PIPE` but only ever reads stderr, and only after `wait()`. If the Swift helper writes >~64 KB to stdout during a long meeting it **blocks forever**. (`coreaudio.py:112-117`, `:154-155`)
- **Stale exit callback tears down the next recording.** `cancelProcessing()` SIGTERMs and nils `running`, but the in-flight `onExit` still fires; start a new recording first and it invalidates the *new* timer, nils `running` (Stop can no longer signal), and flips to `.failed` while the new pipeline keeps recording headless. Needs a per-run token, not a single `cancelled: Bool`. (`AppState.swift:194-211`)
- **The TUI reports failures as successes.** `PipelineProgress.__exit__` moves every active step to completed and prints `✔ … done.` — *including on exception*. A mid-transcription crash prints `✔ Transcribing done.` immediately before the traceback. `Spinner.__exit__` has the same bug. (`progress.py:332-343`, `:51-56`)
- **Xcode build path crashes on mic.** `macapp/Resources/Info.plist` declares `NSScreenRecordingUsageDescription` but **not** `NSMicrophoneUsageDescription` — only `build-app.sh`'s inline heredoc has both. An `xcodegen` + ⌘R build is SIGABRT-killed by TCC on first mic request. Two build paths, two different bundles, already drifted. (verified: `Info.plist:31` vs `build-app.sh:47-50`)
- **Backend typos are validated after the meeting is recorded.** `_create_transcriber` runs at `pipeline.py:271`; `backend = "mlxx"` or MLX on an Intel Mac records the whole meeting, then dies. (The WAV survives, so `resume` works — but it should fail at startup.)
- **Any unrecognised summarizer backend silently becomes Ollama.** `create_summarizer`'s `else` is a catch-all, so `backend = "opneai"` builds an `OllamaSummarizer` pointed at localhost. Meanwhile `_create_transcriber` fails loudly for the same class of typo — inconsistent.
- **No HTTP timeouts anywhere** in `summarization/` or `search.py`. A wedged Ollama/LM Studio hangs indefinitely.
- **No transcript chunking in `summarize()`.** `n_ctx` is hardcoded to 8192 (`llama_cpp_summarizer.py:130`) and ignores `config.summarization.context_size`. A one-hour meeting (~13 k tokens) simply overflows. `search.py` has careful token budgeting; `summarization/` has none.
- **Disk write in the PortAudio real-time callback** — allocation + lock + blocking write. (`sounddevice_recorder.py:58-61`)
- **`_find_audio` is nondeterministic** — `directory.iterdir()` with no `sorted()`. (`pipeline.py:531`)

### P2 — process and hygiene

The repo itself is **clean**: no tracked `.DS_Store`, no committed build artifacts (`macapp/build/` correctly ignored), no secrets, 1.9 MB `.git`, `uv.lock` committed, PyPI publishing via OIDC trusted publisher, and build provenance attestation on the release binary. That's above average for a project this size.

The gaps are in enforcement:

- **`ruff format` is documented but not enforced — and has drifted.** `ruff format --check` reports **15 of 41 files** would be reformatted, including `pipeline.py`, `progress.py`, `cli.py`, `search.py`, `coreaudio.py`. Anyone following `CONTRIBUTING.md` produces a 15-file unrelated diff.
- **No type checking at all**, despite `from __future__ import annotations` and fully annotated signatures throughout. Cheapest available win.
- **The marker machinery guards nothing.** `conftest.py:83-91` auto-skips `hardware`/`macos` tests, `pyproject.toml` declares three markers, CI runs `-m "not hardware"`, and `CONTRIBUTING.md:33` documents it — but **zero tests carry any of those markers**. Four places asserting something untrue.
- **`tests/conftest.py:54-80`'s `synthetic_wav` fixture is referenced by zero tests** — built for exactly the audio coverage that's missing.
- **CI never builds `macapp/`.** 15 SwiftUI files with no automated verification; a compile error would land unnoticed. `build-app.sh` is Xcode-free and would run on the existing macos-14 runner.
- **`swift/Package.swift` cannot link** — declares only `CoreAudio` + `AudioToolbox`, but the source imports `ScreenCaptureKit`, `AVFAudio`, `AppKit`, `CoreGraphics`, `CoreMedia`, `IOKit`. Nothing references it; CI and docs both use `build.sh`. It's a trap.
- **Runtime deps are all unbounded `>=`.** `pyannote-audio>=4.0` has already broken once. Lockfile protects contributors; `uvx ownscribe` users get nothing.

### Test coverage

254 tests on main, 285 on feature. I ran them in a Linux sandbox with only `pytest, click, soundfile, tomlkit, pytest-httpserver` — **215/254 and 246/285 pass with no ML stack at all**, and every non-pass is a `ModuleNotFoundError` for a deliberately-omitted dep. Zero genuine logic failures. That's strong evidence the lazy-import discipline in `AGENTS.md:54` actually holds, and it means a `ubuntu-latest` CI job would be nearly free.

Quality is good where it exists — `test_search.py` and `test_summarization.py` use a real `pytest-httpserver` rather than mocks and cover the 400-fallback degradation paths; `test_pipeline.py` covers real failure modes (`test_summarization_failure_preserves_transcript`).

The gap is concentrated and it's the part that touches hardware:

```
coreaudio.py:  _download_binary  0 refs in tests/
               list_devices      0
               silence_timed_out 0      ← the auto-stop trigger
               silence_warning   0
sounddevice_recorder.py (104 L)  — no test file at all
run_pipeline()                   — never called; appears only as a mock.patch target
AudioCapture.swift (1,078 L)     — zero tests, no Tests/ dir anywhere
macapp/ (15 files)               — zero tests
```

---

## 5. Recommended sequence

**Step 0 — stop the bleeding (do this before any feature work).**

1. Commit the MLX work to a branch. It's finished enough to preserve.
2. `git push origin main` — the MicCapture fix is currently one disk failure from gone.
3. `git rebase main feature/macos-menubar-ui`. Rebase, don't merge: it drops the duplicate `a319f3e` as already-applied, whereas a merge hand-conflicts it. `git merge-tree` shows only `README.md` and `pipeline.py` as "changed in both"; all of `macapp/` is add-only and `AudioCapture.swift` resolves to main's version automatically. **The merge is easy — it's the delay that's expensive.**
4. Cut a release so `build-binary.yml` fires and publishes a helper containing `78142df` — otherwise the fix stays theoretical. This needs `_DOWNLOAD_URL` repointed from `paberr` to `alanderex`, or better, the helper bundled inside `Ownscribe.app`.
5. Replace the branch `pipSpec` with a version/tag spec before it breaks on merge.

**Step 1 — correctness fixes.** P0 items 2–6. Small, isolated, high-value.

**Step 2 — the one improvement that changes how the app feels.** Add a `--json-progress` line-event stream to `PipelineProgress`, parse it incrementally in `CommandRunner`, and drive a real progress UI. It's a Python-side change plus a small Swift change, and it converts "indeterminate spinner for 10 minutes" into an actual progress bar. Everything else on the P1 list is robustness; this one is the product.

**Step 3 — enforcement.** `ruff format --check` in CI (after normalising the 15 drifted files), mypy, a `ubuntu-latest` job, `swiftc` typecheck of `macapp/`, and either use the pytest markers or delete them.

**Step 4 — seams, only if you want the features they unlock.** A `Formatter` protocol in `output/` (SRT/VTT/DOCX are pure functions over `TranscriptResult`, which is already a clean dataclass); a `Diarizer` protocol extracted from `_diarize`; config validation with enum checks so backend typos fail at startup instead of after the meeting.

---

## 6. One thing worth deciding explicitly

You're maintaining a fork with an unpushed commit, a long-lived feature branch, and an untracked feature — three concurrent lines of work on a single-maintainer project. You've already paid for the split once (the duplicated video-input commit) and are currently paying for it in a way that affects real recordings (the missing mic fix).

`CONTRIBUTING.md:46` still solicits "a GUI frontend (Electron, Tauri, or native)" and `:52` still solicits "speaker name assignment" — both of which are **finished** on the feature branch. A contributor reading that today would duplicate your work a third time.

Collapsing to a single branch is the highest-leverage change available, and it costs about an hour.
