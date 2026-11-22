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
from ownscribe.speakers import list_speakers, rename_json, rename_markdown

# A markdown speaker header is `**Name** [mm:ss]`: these would break it, and these
# prefixes would make it read back as a metadata line.
_FORBIDDEN_IN_NAMES = ("*", "[", "]", "\n", "\r")
_METADATA_PREFIXES = ("Language:", "Duration:")


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


def rename_speakers(folder: Path, mapping: dict[str, str]) -> list[Path]:
    """Rename speakers in the folder's transcripts and summaries; returns the files changed.

    Labels mapped to the same name merge. Transcripts change only in their speaker
    labels, never in what was said; summaries change wherever a label stands as a
    whole word.
    """
    with folder_lock(folder, "edit-speakers"):
        transcripts = existing(folder, TRANSCRIPT_NAMES)
        if not transcripts:
            raise click.ClickException(f"No transcript in {folder}.")
        present = {label for path in transcripts for label in list_speakers(path)}
        if unknown := sorted(set(mapping) - present):
            raise click.ClickException(
                f"Not a speaker in {folder.name}: {', '.join(unknown)}. "
                f"Its speakers: {', '.join(sorted(present)) or 'none'}."
            )
        names = {label: check_name(name) for label, name in mapping.items()}

        changes: dict[Path, str] = {}
        for path in transcripts:
            text = _read(path)
            renamed = rename_json(text, names) if path.suffix == ".json" else rename_markdown(text, names)
            if renamed != text:
                changes[path] = renamed
        for path in existing(folder, SUMMARY_NAMES):
            text = _read(path)
            renamed = _rename_in_summary(path, text, names)
            if renamed != text:
                changes[path] = renamed
        save_edits(changes)
        return list(changes)


def revert_speaker_edits(folder: Path) -> list[Path]:
    """Put back every file that has a pre-edit copy; returns the files restored."""
    with folder_lock(folder, "edit-speakers"):
        edited = [path for path in existing_or_original(folder) if original_of(path).is_file()]
        if not edited:
            raise click.ClickException(f"{folder.name} has no copies from before an edit; nothing to restore.")
        for path in edited:
            os.replace(original_of(path), path)
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
    return json.dumps(data, indent=2, ensure_ascii=False)


def _read(path: Path) -> str:
    # Bytes decoded as-is: read_text would turn \r\n into \n and rewrite every line.
    return path.read_bytes().decode("utf-8")
