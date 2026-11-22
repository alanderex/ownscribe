"""Per-meeting app metadata in `<folder>/.ownscribe.json`.

Facts about a meeting that no transcript or summary file carries: for now whether
the summary predates a speaker move. Written atomically, by processes that hold the
folder lock or write the summary themselves.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import click

from ownscribe.fileio import write_atomic

META_NAME = ".ownscribe.json"
META_SCHEMA = 1


def read_meta(folder: Path) -> dict[str, Any]:
    """The folder's metadata; empty when the file does not exist."""
    path = folder / META_NAME
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise click.ClickException(f"{path} is not valid JSON: {exc}") from None
    if not isinstance(data, dict):
        raise click.ClickException(f"{path} holds {type(data).__name__}, not an object.")
    return data


def summary_is_stale(folder: Path) -> bool:
    """True after a speaker move that the summary was written before."""
    return read_meta(folder).get("summary_stale") is True


def mark_summary_stale(folder: Path) -> None:
    _update(folder, summary_stale=True)


def clear_summary_stale(folder: Path) -> None:
    """Forget the stale mark; writes nothing when there is none."""
    if summary_is_stale(folder):
        _update(folder, summary_stale=None)


def _update(folder: Path, **changes: Any) -> None:
    """Merge `changes` into the metadata; a None value removes that key."""
    data = read_meta(folder)
    for key, value in changes.items():
        if value is None:
            data.pop(key, None)
        else:
            data[key] = value
    data["schema"] = META_SCHEMA
    write_atomic(folder / META_NAME, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
