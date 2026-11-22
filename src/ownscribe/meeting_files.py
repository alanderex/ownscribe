"""The files a meeting folder holds, named in one place."""

from __future__ import annotations

from pathlib import Path

# transcript.json carries real segment end times, so it wins when both exist.
TRANSCRIPT_NAMES = ("transcript.json", "transcript.md")
SUMMARY_NAMES = ("summary.json", "summary.md")

# `edit-speakers` keeps a one-time copy of each file as it was before the first edit.
ORIGINAL_SUFFIX = ".orig"
ORIGINAL_NAMES = tuple(name + ORIGINAL_SUFFIX for name in TRANSCRIPT_NAMES + SUMMARY_NAMES)


def original_of(path: Path) -> Path:
    """Where the pre-edit copy of `path` lives."""
    return path.with_name(path.name + ORIGINAL_SUFFIX)


def existing(folder: Path, names: tuple[str, ...]) -> list[Path]:
    """The files among `names` that exist in `folder`, in the order given."""
    return [folder / name for name in names if (folder / name).is_file()]
