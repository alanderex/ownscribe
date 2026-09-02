"""CLI entry point for ownscribe."""

from __future__ import annotations

import os
import shutil
import subprocess

import click

from ownscribe.config import CONFIG_DIR, Config, ensure_config_file

# Canonical paths for cleanup
_CACHE_DIR = os.path.expanduser("~/.local/share/ownscribe")
_CONFIG_DIR = str(CONFIG_DIR)


def _dir_size(path: str) -> str:
    """Human-readable size of a directory tree, or '(not found)' if missing."""
    from pathlib import Path

    p = Path(path)
    if not p.exists():
        return "(not found)"
    total = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    for unit in ("B", "KB", "MB", "GB"):
        if total < 1024:
            return f"{total:.1f} {unit}"
        total /= 1024
    return f"{total:.1f} TB"


@click.group(invoke_without_command=True)
@click.option("--device", default=None, help="Audio input device name or index.")
@click.option("--no-summarize", is_flag=True, help="Skip LLM summarization.")
@click.option("--diarize", is_flag=True, help="Enable speaker diarization (needs HF token).")
@click.option("--format", "output_format", type=click.Choice(["markdown", "json"]), default=None, help="Output format.")
@click.option("--model", default=None, help="Whisper model size (tiny, base, small, medium, large-v3).")
@click.option("--language", default=None, help="Language code for transcription (e.g. en, de, fr).")
@click.option("--initial-prompt", default=None, help="Context text to prime Whisper (vocab, speaker names, etc.)")
@click.option("--hotwords", default=None, help="Comma-separated words to boost Whisper recognition.")
@click.option(
    "--mic/--no-mic",
    default=None,
    help="Also capture microphone input (mixed with system audio); on by default.",
)
@click.option("--mic-device", default=None, help="Specific mic device name (implies --mic).")
@click.option(
    "--keep-recording/--no-keep-recording",
    default=None,
    help="Keep or delete WAV recordings after transcription.",
)
@click.option("--template", default=None, help="Summarization template (meeting, lecture, brief, or custom).")
@click.option(
    "--silence-timeout", default=None, type=click.IntRange(min=0),
    help="Seconds of silence before auto-stopping recording (0 to disable).",
)
@click.option(
    "--speakers", default=None, type=click.IntRange(min=1),
    help="Exact number of speakers for diarization (sets min and max).",
)
@click.option(
    "--title", default=None,
    help="Name this meeting; the output folder becomes YYMMDD-your-title.",
)
@click.pass_context
def cli(
    ctx: click.Context,
    title: str | None,
    device: str | None,
    no_summarize: bool,
    diarize: bool,
    output_format: str | None,
    model: str | None,
    language: str | None,
    initial_prompt: str | None,
    hotwords: str | None,
    mic: bool | None,
    mic_device: str | None,
    keep_recording: bool | None,
    template: str | None,
    silence_timeout: int | None,
    speakers: int | None,
) -> None:
    """Fully local meeting transcription and summarization.

    Run without a subcommand to record, transcribe, and summarize a meeting.
    """
    ctx.ensure_object(dict)
    try:
        config = Config.load()
    except ValueError as exc:
        raise click.ClickException(str(exc)) from None

    # Apply CLI overrides
    if device is not None:
        config.audio.device = device
        if config.audio.backend == "coreaudio" and device:
            config.audio.backend = "sounddevice"
    if no_summarize:
        config.summarization.enabled = False
    if diarize:
        config.diarization.enabled = True
    if output_format:
        config.output.format = output_format
    if model:
        config.transcription.model = model
    # `--language ""` explicitly forces auto-detect, overriding a configured
    # default — so test against None, not truthiness.
    if language is not None:
        config.transcription.language = language
    if initial_prompt:
        config.transcription.initial_prompt = initial_prompt
    if hotwords:
        config.transcription.hotwords = hotwords
    if mic is False and mic_device:
        raise click.UsageError("--no-mic and --mic-device cannot be used together.")
    if mic is not None:
        config.audio.mic = mic
    if mic_device:
        config.audio.mic = True
        config.audio.mic_device = mic_device
    if keep_recording is not None:
        config.output.keep_recording = keep_recording
    if template:
        config.summarization.template = template
    if silence_timeout is not None:
        config.audio.silence_timeout = silence_timeout
    if speakers is not None:
        config.diarization.min_speakers = speakers
        config.diarization.max_speakers = speakers

    ctx.obj["config"] = config

    if ctx.invoked_subcommand is None:
        from ownscribe.pipeline import run_pipeline
        # Per-run, not config: a title belongs to one meeting, never persisted.
        run_pipeline(config, title=title)


@cli.command()
@click.argument("question")
@click.option("--since", default=None, help="Only search meetings after this date (YYYY-MM-DD).")
@click.option("--limit", default=None, type=int, help="Max number of recent meetings to search.")
@click.pass_context
def ask(ctx: click.Context, question: str, since: str | None, limit: int | None) -> None:
    """Ask a question across your meeting notes."""
    config = ctx.obj["config"]
    from ownscribe.search import ask as run_ask

    run_ask(config, question, since=since, limit=limit)


@cli.command()
def devices() -> None:
    """List available audio input devices."""
    from ownscribe.audio.coreaudio import CoreAudioRecorder
    recorder = CoreAudioRecorder()
    if recorder.is_available():
        click.echo(recorder.list_devices())
    else:
        import sounddevice as sd
        click.echo("Available audio devices:\n")
        click.echo(sd.query_devices())


@cli.command()
@click.argument("file", type=click.Path(exists=True))
@click.option("--diarize", is_flag=True, help="Enable speaker diarization.")
@click.option("--model", default=None, help="Whisper model size.")
@click.option("--language", default=None, help="Language code for transcription (e.g. en, de, fr).")
@click.option(
    "--speakers", default=None, type=click.IntRange(min=1),
    help="Exact number of speakers for diarization (sets min and max).",
)
@click.option("--format", "output_format", type=click.Choice(["markdown", "json"]), default=None)
@click.pass_context
def transcribe(
    ctx: click.Context, file: str, diarize: bool,
    model: str | None, language: str | None, speakers: int | None, output_format: str | None,
) -> None:
    """Transcribe an audio file."""
    config = ctx.obj["config"]
    if diarize:
        config.diarization.enabled = True
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if speakers is not None:
        config.diarization.min_speakers = speakers
        config.diarization.max_speakers = speakers
    if output_format:
        config.output.format = output_format

    from ownscribe.pipeline import run_transcribe
    run_transcribe(config, file)


@cli.command()
@click.option("--model", default=None, help="Whisper model size.")
@click.option("--language", default=None, help="Language code to prefetch alignment model for (e.g. en, de, fr).")
@click.option(
    "--with-diarization/--no-diarization",
    "with_diarization",
    default=None,
    help="Override diarization warmup (defaults to config setting).",
)
@click.pass_context
def warmup(
    ctx: click.Context,
    model: str | None,
    language: str | None,
    with_diarization: bool | None,
) -> None:
    """Prefetch WhisperX/pyannote models to avoid first-run stalls."""
    config = ctx.obj["config"]
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if with_diarization is not None:
        config.diarization.enabled = with_diarization

    from ownscribe.pipeline import run_warmup
    run_warmup(config)


@cli.command()
@click.argument("file", type=click.Path(exists=True))
@click.option("--template", default=None, help="Summarization template (meeting, lecture, brief, or custom).")
@click.pass_context
def summarize(ctx: click.Context, file: str, template: str | None) -> None:
    """Summarize a transcript file."""
    config = ctx.obj["config"]
    if template:
        config.summarization.template = template

    from ownscribe.pipeline import run_summarize
    run_summarize(config, file)


@cli.command()
@click.argument("directory", type=click.Path(exists=True, file_okay=False))
@click.option("--model", default=None, help="Whisper model size (tiny, base, small, medium, large-v3).")
@click.option("--language", default=None, help="Language code for transcription (e.g. en, de, fr).")
@click.option("--template", default=None, help="Summarization template (meeting, lecture, brief, or custom).")
@click.pass_context
def resume(
    ctx: click.Context, directory: str,
    model: str | None, language: str | None, template: str | None,
) -> None:
    """Resume a partially-completed pipeline in a meeting directory."""
    config = ctx.obj["config"]
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if template:
        config.summarization.template = template

    from ownscribe.pipeline import run_resume
    run_resume(config, directory)


@cli.command()
def apps() -> None:
    """List running apps with PIDs for use with --pid."""
    from ownscribe.audio.coreaudio import CoreAudioRecorder
    recorder = CoreAudioRecorder()
    click.echo(recorder.list_apps())


@cli.group("config", invoke_without_command=True)
@click.pass_context
def config_cmd(ctx: click.Context) -> None:
    """Open the configuration file in your editor, or get/set values.

    With no subcommand, opens config.toml in $EDITOR. Use `config get` to print
    the effective configuration as JSON and `config set` to change a value while
    preserving the file's comments.
    """
    if ctx.invoked_subcommand is not None:
        return
    path = ensure_config_file()
    editor = os.environ.get("EDITOR", "nano")
    click.echo(f"Opening {path} with {editor}...")
    subprocess.run([editor, str(path)])


@config_cmd.command("get")
@click.option("--reveal-secrets", is_flag=True, help="Include api_key/hf_token values (redacted by default).")
@click.pass_context
def config_get(ctx: click.Context, reveal_secrets: bool) -> None:
    """Print the effective configuration as JSON (secrets redacted by default)."""
    from ownscribe.config_io import config_to_json

    click.echo(config_to_json(ctx.obj["config"], reveal_secrets=reveal_secrets))


@config_cmd.command("set")
@click.argument("key")
@click.argument("value")
def config_set(key: str, value: str) -> None:
    """Set a config value, e.g. `config set summarization.backend openai`."""
    from ownscribe.config_io import set_config_value

    try:
        path = set_config_value(key, value)
    except ValueError as exc:
        click.echo(f"Error: {exc}", err=True)
        raise SystemExit(1) from None
    click.echo(f"Set {key} = {value} in {path}")


def _parse_speaker_map(pairs: tuple[str, ...]) -> dict[str, str]:
    """Parse `LABEL=Name` pairs into a mapping, failing loudly on bad input."""
    mapping: dict[str, str] = {}
    for pair in pairs:
        label, sep, name = pair.partition("=")
        label = label.strip()
        name = name.strip()
        if not sep or not label or not name:
            raise click.BadParameter(
                f"Expected LABEL=Name, got {pair!r}", param_hint="--map"
            )
        if "\n" in name:
            raise click.BadParameter(f"Name may not contain newlines: {name!r}", param_hint="--map")
        mapping[label] = name
    return mapping


@cli.command("list-speakers")
@click.argument("transcript", type=click.Path(exists=True, dir_okay=False))
def list_speakers_cmd(transcript: str) -> None:
    """List distinct speaker labels in a transcript (JSON array)."""
    import json
    from pathlib import Path

    from ownscribe.speakers import list_speakers

    click.echo(json.dumps(list_speakers(Path(transcript))))


@cli.command("rename-speakers")
@click.argument("transcript", type=click.Path(exists=True, dir_okay=False))
@click.option(
    "--map", "maps", multiple=True, required=True, metavar="LABEL=Name",
    help="Rename a speaker label, e.g. --map SPEAKER_00=Anna (repeatable).",
)
def rename_speakers_cmd(transcript: str, maps: tuple[str, ...]) -> None:
    """Rename speaker labels in a transcript file (in place)."""
    from pathlib import Path

    from ownscribe.speakers import apply_rename

    mapping = _parse_speaker_map(maps)
    renamed = apply_rename(Path(transcript), mapping)
    click.echo(f"Renamed {renamed} speaker(s) in {transcript}")


@cli.command()
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts.")
@click.option("--all", "all_", is_flag=True, help="Remove everything (config + cache + output).")
@click.option("--config", "config_", is_flag=True, help="Remove config directory (~/.config/ownscribe/).")
@click.option("--cache", is_flag=True, help="Remove cached binary (~/.local/share/ownscribe/).")
@click.option("--output", is_flag=True, help="Remove output directory with recordings/transcripts.")
@click.pass_context
def cleanup(
    ctx: click.Context,
    yes: bool,
    all_: bool,
    config_: bool,
    cache: bool,
    output: bool,
) -> None:
    """Remove ownscribe data from disk (config, cache, recordings)."""
    cfg = ctx.obj["config"]
    output_dir = str(cfg.output.resolved_dir)
    audio_dir = str(cfg.output.resolved_audio_dir)

    targets: list[tuple[str, str]] = []

    if all_:
        targets = [
            ("Config", _CONFIG_DIR),
            ("Cache", _CACHE_DIR),
            ("Output", output_dir),
        ]
        if audio_dir != output_dir:
            targets.append(("Audio", audio_dir))
    elif config_ or cache or output:
        if config_:
            targets.append(("Config", _CONFIG_DIR))
        if cache:
            targets.append(("Cache", _CACHE_DIR))
        if output:
            targets.append(("Output", output_dir))
            if audio_dir != output_dir:
                targets.append(("Audio", audio_dir))
    else:
        candidates = [
            ("Config", _CONFIG_DIR),
            ("Cache", _CACHE_DIR),
            ("Output", output_dir),
        ]
        if audio_dir != output_dir:
            candidates.append(("Audio", audio_dir))
        # --yes means "don't ask me about the targets I named", not "delete
        # everything". Bare `cleanup -y` used to auto-confirm config, cache, output
        # and audio in one go — every recording, transcript and summary — with no
        # summary and no prompt. Require an explicit target instead.
        if yes:
            raise click.UsageError(
                "cleanup --yes needs an explicit target: --all, --config, --cache, "
                "or --output. Run `ownscribe cleanup` with no flags to choose "
                "interactively."
            )
        # Interactive: prompt for each directory
        for label, path in candidates:
            size = _dir_size(path)
            if size == "(not found)":
                click.echo(f"  {label}: {path} — {size}, skipping")
                continue
            if click.confirm(f"  Remove {label}: {path} ({size})?"):
                targets.append((label, path))
        if not targets:
            click.echo("Nothing to remove.")
        return _remove_targets(targets)

    if not yes:
        click.echo("The following directories will be removed:")
        for label, path in targets:
            click.echo(f"  {label}: {path} ({_dir_size(path)})")
        if not click.confirm("Proceed?"):
            click.echo("Aborted.")
            return

    _remove_targets(targets)


def _remove_targets(targets: list[tuple[str, str]]) -> None:
    """Delete the listed directories."""
    from pathlib import Path

    for label, path in targets:
        p = Path(path)
        if p.exists():
            shutil.rmtree(p)
            click.echo(f"  Removed {label}: {path}")
        else:
            click.echo(f"  {label}: {path} — not found, skipping")
