"""Tags on meetings, kept in each meeting folder's `.ownscribe.json`.

Tags group meetings across the library, by project or client. They compare
case-insensitively, and a tag has one spelling in the library: the one in the first
folder, by name, that has it. So "clientx" typed on a new meeting joins an existing
"ClientX" instead of starting a second tag. Every write holds the folder's lock.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

import click

from ownscribe.config import Config
from ownscribe.locks import folder_lock
from ownscribe.meeting_files import meeting_folders
from ownscribe.meeting_meta import META_NAME, read_meta, update_meta

TAGS_KEY = "tags"


@dataclass(frozen=True)
class LibraryTag:
    """One tag across the library: its spelling and the folders that have it."""

    name: str
    folders: tuple[Path, ...]

    @property
    def count(self) -> int:
        return len(self.folders)


def check_tag(text: str) -> str:
    """The tag as stored: trimmed, non-empty, on one line."""
    tag = text.strip()
    if not tag:
        raise click.BadParameter("A tag may not be empty.")
    if "\n" in tag or "\r" in tag:
        raise click.BadParameter(f"A tag may not contain line breaks: {tag!r}")
    return tag


def meeting_tags(folder: Path, meta: dict | None = None) -> list[str]:
    """The folder's tags as stored, from `meta` when the caller has read it already."""
    data = read_meta(folder) if meta is None else meta
    tags = data.get(TAGS_KEY, [])
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise click.ClickException(f"{folder / META_NAME}: {TAGS_KEY} must be a list of text, got {tags!r}")
    return tags


def group_tags(folder_tags: Iterable[tuple[Path, Sequence[str]]]) -> dict[str, LibraryTag]:
    """The library's tags keyed by their case-folded form, from (folder, tags) pairs
    given in folder-name order; the first spelling seen is the library's."""
    spellings: dict[str, str] = {}
    folders: dict[str, list[Path]] = {}
    for folder, tags in folder_tags:
        for tag in tags:
            key = tag.casefold()
            spellings.setdefault(key, tag)
            having = folders.setdefault(key, [])
            if not having or having[-1] != folder:
                having.append(folder)
    return {key: LibraryTag(spellings[key], tuple(having)) for key, having in folders.items()}


def library_tags(config: Config) -> dict[str, LibraryTag]:
    """Every tag in the output directory, keyed by its case-folded form."""
    return group_tags((folder, meeting_tags(folder)) for folder in meeting_folders(config.output.resolved_dir))


def edit_tags(config: Config, folder: Path, *, add: Sequence[str], remove: Sequence[str]) -> list[str]:
    """Add and remove the meeting's tags; returns its tags afterwards.

    An added tag takes the library's spelling and is skipped when the meeting has
    it already. Removing a tag the meeting does not have is an error: it is more
    likely a typo than a request that is already satisfied.
    """
    added = [check_tag(tag) for tag in add]
    removed = [check_tag(tag) for tag in remove]
    removed_keys = {tag.casefold() for tag in removed}
    if both := [tag for tag in added if tag.casefold() in removed_keys]:
        raise click.UsageError(f"Cannot add and remove the same tag: {', '.join(both)}")
    library = library_tags(config)

    with folder_lock(folder, "tag"):
        current = meeting_tags(folder)
        current_keys = {tag.casefold() for tag in current}
        if missing := [tag for tag in removed if tag.casefold() not in current_keys]:
            has = ", ".join(current) if current else "no tags"
            raise click.ClickException(f"{folder.name} has no tag {', '.join(missing)} (it has {has}).")
        tags = [tag for tag in current if tag.casefold() not in removed_keys]
        for tag in added:
            key = tag.casefold()
            if key not in {kept.casefold() for kept in tags}:
                known = library.get(key)
                tags.append(known.name if known else tag)
        if tags != current:
            update_meta(folder, **{TAGS_KEY: tags or None})
    return tags
