"""A meeting's own title, kept in its folder's `.ownscribe.json`.

Every meeting has a title from its folder name (`show.folder_title`), but a folder
name holds a slug: "KIBV RGSW" comes back as "Kibv Rgsw", and renaming the folder
would move whatever points at it. A title set here is shown exactly as typed
instead, and the folder keeps its name.
"""

from __future__ import annotations

from pathlib import Path

import click

from ownscribe.locks import folder_lock
from ownscribe.meeting_meta import META_NAME, update_meta

TITLE_KEY = "title"


def check_title(text: str) -> str:
    """The title as stored: trimmed, non-empty, on one line."""
    title = text.strip()
    if not title:
        raise click.BadParameter("A title may not be empty.")
    if "\n" in title or "\r" in title:
        raise click.BadParameter(f"A title may not contain line breaks: {title!r}")
    return title


def stored_title(folder: Path, meta: dict) -> str | None:
    """The title set for the meeting, or None when it has only its folder's."""
    title = meta.get(TITLE_KEY)
    if title is not None and not isinstance(title, str):
        raise click.ClickException(f"{folder / META_NAME}: {TITLE_KEY} must be text, got {title!r}")
    return title or None


def set_title(folder: Path, text: str) -> str:
    """Give the meeting a title of its own, under the folder lock; returns it."""
    title = check_title(text)
    with folder_lock(folder, "title"):
        update_meta(folder, **{TITLE_KEY: title})
    return title
