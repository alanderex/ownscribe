"""Per-meeting app metadata in `<folder>/.ownscribe.json`.

Facts about a meeting that no transcript or summary file carries: whether the
summary predates a speaker move, and the meeting's tags. Written atomically, by
processes that hold the folder lock.
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


def summary_is_stale(folder: Path, meta: dict[str, Any] | None = None) -> bool:
    """True after a speaker move that the summary was written before; `meta` is the
    folder's metadata when the caller has read it already."""
    return (read_meta(folder) if meta is None else meta).get("summary_stale") is True


SUMMARY_REQUEST_KEY = "summary_request"
_SUMMARY_REQUEST_FIELDS = ("backend", "model", "template", "instructions")


def summary_request(folder: Path, meta: dict[str, Any]) -> dict[str, str] | None:
    """What the current summary was written with (backend, model, template,
    instructions), or None for a summary from before this was recorded."""
    request = meta.get(SUMMARY_REQUEST_KEY)
    if request is None:
        return None
    if not isinstance(request, dict) or not all(isinstance(request.get(f), str) for f in _SUMMARY_REQUEST_FIELDS):
        raise click.ClickException(
            f"{folder / META_NAME}: {SUMMARY_REQUEST_KEY} must hold text for {', '.join(_SUMMARY_REQUEST_FIELDS)}."
        )
    return {field: request[field] for field in _SUMMARY_REQUEST_FIELDS}


def record_summary(folder: Path, *, backend: str, model: str, template: str, instructions: str) -> None:
    """A summary was just written: keep what it was written with, and forget any
    stale mark, since it reflects the transcript as it is now."""
    request = {"backend": backend, "model": model, "template": template, "instructions": instructions}
    update_meta(folder, summary_stale=None, **{SUMMARY_REQUEST_KEY: request})


def forget_summary_request(folder: Path) -> None:
    """The summary file was replaced by one this does not describe."""
    if SUMMARY_REQUEST_KEY in read_meta(folder):
        update_meta(folder, **{SUMMARY_REQUEST_KEY: None})


def mark_summary_stale(folder: Path) -> None:
    update_meta(folder, summary_stale=True)


def clear_summary_stale(folder: Path) -> None:
    """Forget the stale mark; writes nothing when there is none."""
    if summary_is_stale(folder):
        update_meta(folder, summary_stale=None)


def update_meta(folder: Path, **changes: Any) -> None:
    """Merge `changes` into the metadata; a None value removes that key.

    The caller holds the folder's lock: this reads, changes and writes the file.
    """
    data = read_meta(folder)
    for key, value in changes.items():
        if value is None:
            data.pop(key, None)
        else:
            data[key] = value
    data["schema"] = META_SCHEMA
    write_atomic(folder / META_NAME, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
