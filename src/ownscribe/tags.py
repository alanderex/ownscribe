"""Tags on meetings, kept in each meeting folder's `.ownscribe.json`.

Tags group meetings across the library, by project or client. They compare
case-insensitively, and a tag has one spelling in the library: the one in the first
folder, by name, that has it. So "clientx" typed on a new meeting joins an existing
"ClientX" instead of starting a second tag. Every write holds the folder's lock.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

import click

from ownscribe.config import Config
from ownscribe.locks import BUSY_EXIT_CODE, FolderBusyError, folder_lock, probe
from ownscribe.meeting_files import meeting_folders
from ownscribe.meeting_meta import META_NAME, read_meta, update_meta

TAGS_KEY = "tags"

#: Schema of `tags --json`; bumped when a field changes meaning or disappears.
TAGS_SCHEMA = 1


class TagBusyError(click.ClickException):
    """Meetings with the tag were busy, so it was not removed from them; exits 75."""

    exit_code = BUSY_EXIT_CODE


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


def in_library_spelling(tags: Sequence[str], library: Mapping[str, LibraryTag]) -> list[str]:
    """A meeting's tags as the library spells them, each once, in the meeting's order.

    `show --list` reports them so, and the app matches tags exactly instead of
    folding case itself.
    """
    return list(dict.fromkeys(library[tag.casefold()].name for tag in tags))


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


def tags_listing(library: Mapping[str, LibraryTag]) -> list[dict]:
    """Each tag's name and meeting count, by name: what `tags --json` and
    `show --list` report."""
    return [{"name": tag.name, "count": tag.count} for tag in sorted(library.values(), key=lambda t: t.name.casefold())]


def delete_tag(config: Config, text: str) -> LibraryTag:
    """Remove a tag, in any spelling, from every meeting; returns it as it was.

    When a meeting with the tag is busy, nothing is changed: a tag deleted from
    some meetings only would come back in the list. A folder that becomes busy
    after that check stops the deletion there, and the error says which meetings
    still have the tag.
    """
    tag = check_tag(text)
    key = tag.casefold()
    found = library_tags(config).get(key)
    if found is None:
        raise click.ClickException(f"No meeting has the tag '{tag}'.")
    if busy := [folder for folder in found.folders if probe(folder).busy is True]:
        raise TagBusyError(
            f"Nothing changed: {_meetings(len(busy))} with '{found.name}' "
            f"{'is' if len(busy) == 1 else 'are'} busy now:\n{_lines(busy)}\nTry again once they have finished."
        )
    changed: list[Path] = []
    for folder in found.folders:
        try:
            with folder_lock(folder, "tag"):
                tags = meeting_tags(folder)
                kept = [kept for kept in tags if kept.casefold() != key]
                if kept != tags:
                    update_meta(folder, **{TAGS_KEY: kept or None})
        except FolderBusyError:
            left = found.folders[len(changed) :]
            raise TagBusyError(
                f"Removed '{found.name}' from {_meetings(len(changed))}; these became busy and still have it:\n"
                f"{_lines(left)}\nRun the command again once they have finished."
            ) from None
        changed.append(folder)
    return found


def _meetings(count: int) -> str:
    return "1 meeting" if count == 1 else f"{count} meetings"


def _lines(folders: Iterable[Path]) -> str:
    return "\n".join(f"  {folder}" for folder in folders)
