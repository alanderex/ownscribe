"""Speaker edits on a whole meeting folder: rename and merge speakers, and undo it.

`edit-speakers` works on the folder, not one file. The transcript names speakers in
its headers (markdown) or `speaker` fields (JSON), and the summary was written from
text that carried those labels, so it names them too. Both change together, under
the folder lock, after a one-time copy of each changed file as it was before the
first edit; `--revert` puts those copies back.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

import click

from ownscribe.fileio import write_atomic
from ownscribe.locks import folder_lock
from ownscribe.meeting_files import SUMMARY_NAMES, TRANSCRIPT_NAMES, existing, original_of
from ownscribe.meeting_meta import clear_summary_stale, forget_summary_request, mark_summary_stale
from ownscribe.output.json_output import dump_json
from ownscribe.output.markdown import format_transcript
from ownscribe.speakers import list_speakers_json, list_speakers_markdown, rename_json, rename_markdown
from ownscribe.transcript_io import TranscriptFile, read_transcript

# A markdown speaker header is `**Name** [mm:ss]`: these would break it, and these
# prefixes would make it read back as a metadata line.
_FORBIDDEN_IN_NAMES = ("*", "[", "]", "\n", "\r")
_METADATA_PREFIXES = ("Language:", "Duration:")

#: EX_DATAERR: the caller's line numbers refer to a transcript that has since changed.
TRANSCRIPT_CHANGED_EXIT_CODE = 65


def check_name(name: str) -> str:
    """The speaker name, trimmed; raises ClickException naming what is wrong with it."""
    trimmed = name.strip()
    if not trimmed:
        raise click.ClickException("A speaker name may not be empty.")
    if bad := [ch for ch in _FORBIDDEN_IN_NAMES if ch in trimmed]:
        shown = ", ".join(repr(ch) for ch in bad)
        raise click.ClickException(f"Speaker name {trimmed!r} contains {shown}, which a transcript cannot hold.")
    if trimmed.startswith(_METADATA_PREFIXES):
        raise click.ClickException(f"Speaker name {trimmed!r} would read back as transcript metadata.")
    return trimmed


class TranscriptChangedError(click.ClickException):
    """The transcript changed since its revision was read, so its line numbers may not hold."""

    exit_code = TRANSCRIPT_CHANGED_EXIT_CODE


def edit_speakers(
    folder: Path,
    *,
    renames: dict[str, str] | None = None,
    moves: dict[int, str] | None = None,
    revision: str | None = None,
) -> list[Path]:
    """Move lines to other speakers, then rename speakers, across the folder's files.

    `moves` maps a line (a segment index as `show DIR --json` numbers them) to a
    speaker: an existing label or a new name. `renames` maps labels to names; labels
    mapped to one name merge. Moves come first, so a rename also covers lines just
    moved to that label. `revision`, from the same `show`, must still match the
    transcript; moves require it. Returns the files changed.

    Transcripts change only in their speakers, never in what was said; a move
    rewrites a markdown transcript in ownscribe's layout. Summaries change where a
    renamed label stands as a whole word, and a move marks the summary stale.
    """
    renames = renames or {}
    moves = moves or {}
    with folder_lock(folder, "edit-speakers"):
        current = read_transcript(folder)
        if current is None:
            raise click.ClickException(f"No transcript in {folder}.")
        if revision is not None and current.revision != revision:
            raise TranscriptChangedError(f"{current.path.name} changed since it was read; read it again and retry.")
        transcripts = existing(folder, TRANSCRIPT_NAMES)
        before = {path: _read(path) for path in transcripts}
        after = dict(before)

        moved = False
        if moves:
            if revision is None:
                raise click.UsageError("Moving lines needs --revision, from `ownscribe show DIR --json`.")
            if len(transcripts) > 1:
                raise click.ClickException(
                    f"{folder.name} holds {' and '.join(path.name for path in transcripts)}; "
                    "moving lines needs a single transcript."
                )
            after[current.path], moved = _move_lines(current, moves)

        present = {label for path, text in after.items() for label in _labels(path, text)}
        if unknown := sorted(set(renames) - present):
            raise click.ClickException(
                f"Not a speaker in {folder.name}: {', '.join(unknown)}. "
                f"Its speakers: {', '.join(sorted(present)) or 'none'}."
            )
        names = {label: check_name(name) for label, name in renames.items()}

        changes: dict[Path, str] = {}
        for path, text in after.items():
            if names:
                text = rename_json(text, names) if path.suffix == ".json" else rename_markdown(text, names)
            if text != before[path]:
                changes[path] = text
        if names:
            for path in existing(folder, SUMMARY_NAMES):
                text = _read(path)
                renamed = _rename_in_summary(path, text, names)
                if renamed != text:
                    changes[path] = renamed
        save_edits(changes)
        if moved and existing(folder, SUMMARY_NAMES):
            mark_summary_stale(folder)
        return list(changes)


def _move_lines(current: TranscriptFile, moves: dict[int, str]) -> tuple[str, bool]:
    """The transcript text with each moved line's speaker set; and whether any changed."""
    result = current.result
    if result is None:
        raise click.ClickException(f"{current.path.name} is not a transcript ownscribe can read back.")
    segments = result.segments
    if missing := sorted(i for i in moves if not (0 <= i < len(segments) and segments[i].text.strip())):
        raise click.ClickException(
            f"{current.path.name} has no line {', '.join(map(str, missing))}; "
            "use the segment indices from `ownscribe show DIR --json`."
        )
    targets = {index: check_name(name) for index, name in moves.items()}
    if all(segments[index].speaker == target for index, target in targets.items()):
        return current.text, False

    if current.is_json:
        data = json.loads(current.text)
        # The same entries parse_transcript_json keeps, so the indices line up.
        entries = [entry for entry in data["segments"] if isinstance(entry, dict)]
        for index, target in targets.items():
            entries[index]["speaker"] = target
            for word in entries[index].get("words", []):
                if isinstance(word, dict):
                    word["speaker"] = target
        return dump_json(data), True

    for index, target in targets.items():
        segments[index].speaker = target
    return format_transcript(result), True


def _labels(path: Path, text: str) -> list[str]:
    return list_speakers_json(text) if path.suffix == ".json" else list_speakers_markdown(text)


def revert_speaker_edits(folder: Path) -> list[Path]:
    """Put back every file that has a pre-edit copy; returns the files restored."""
    with folder_lock(folder, "edit-speakers"):
        edited = [path for path in existing_or_original(folder) if original_of(path).is_file()]
        if not edited:
            raise click.ClickException(f"{folder.name} has no copies from before an edit; nothing to restore.")
        for path in edited:
            os.replace(original_of(path), path)
        clear_summary_stale(folder)
        if any(path.name in SUMMARY_NAMES for path in edited):
            forget_summary_request(folder)
        return edited


def existing_or_original(folder: Path) -> list[Path]:
    """Every transcript and summary path that exists or has a pre-edit copy."""
    paths = [folder / name for name in TRANSCRIPT_NAMES + SUMMARY_NAMES]
    return [path for path in paths if path.is_file() or original_of(path).is_file()]


def save_edits(changes: dict[Path, str]) -> None:
    """Write the changed files, first keeping a copy of each as it was before any edit.

    A file that already has its copy keeps it: Restore returns to the state before
    the first edit, not the last one. Every change is computed before this runs, so
    a refused edit writes nothing.
    """
    for path in changes:
        original = original_of(path)
        if not original.exists():
            write_atomic(original, path.read_bytes())
    for path, text in changes.items():
        write_atomic(path, text)


def rename_words(text: str, mapping: dict[str, str]) -> str:
    """Replace each label where it stands as a whole word, all in one pass.

    One pass lets two names swap. Longest labels go first, so `Anna Lee` is not
    caught as `Anna`; the word boundaries keep `SPEAKER_1` out of `SPEAKER_10`; a
    callable replacement keeps backslashes and `$` in names literal.
    """
    if not mapping:
        return text
    alternatives = "|".join(re.escape(label) for label in sorted(mapping, key=len, reverse=True))
    return re.sub(rf"(?<!\w)(?:{alternatives})(?!\w)", lambda match: mapping[match.group(0)], text)


def _rename_in_summary(path: Path, text: str, mapping: dict[str, str]) -> str:
    if path.suffix != ".json":
        return rename_words(text, mapping)
    data = json.loads(text)
    if not isinstance(data, dict) or not isinstance(data.get("summary"), str):
        raise click.ClickException(f'{path} is not a summary ownscribe wrote: expected {{"summary": text}}.')
    data["summary"] = rename_words(data["summary"], mapping)
    return dump_json(data)


def _read(path: Path) -> str:
    # Bytes decoded as-is: read_text would turn \r\n into \n and rewrite every line.
    return path.read_bytes().decode("utf-8")
