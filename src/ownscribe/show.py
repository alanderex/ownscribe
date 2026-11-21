"""Read-only descriptions of meeting folders, as data for front-ends.

`ownscribe show DIR --json` describes one meeting; `ownscribe show --list --json`
lists every meeting folder in the output directory. The menu-bar app reads these
instead of parsing transcripts itself, so the transcript formats stay known to
Python alone.

Nothing here may import the transcription or summarization stacks: the app runs
`show --list` on every library refresh.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime
from itertools import pairwise
from pathlib import Path

from ownscribe.config import Config
from ownscribe.output.json_output import parse_transcript_json
from ownscribe.output.markdown import parse_transcript
from ownscribe.pipeline import _find_summary, find_meeting_audio
from ownscribe.transcription.models import Segment, TranscriptResult

#: Bumped when a field changes meaning or disappears; new fields do not bump it.
SCHEMA_VERSION = 1

# transcript.json carries real segment end times, so it wins when both exist.
_TRANSCRIPT_NAMES = ("transcript.json", "transcript.md")

# The one-time copies `edit-speakers` keeps before it first renames speakers.
_ORIGINAL_NAMES = ("transcript.json.orig", "transcript.md.orig", "summary.json.orig", "summary.md.orig")

# Folder names start with the meeting's day: `YYMMDD-…` from this version, and
# `YYYY-MM-DD` followed by `_` or `-` from older versions and hand-named folders.
_SHORT_DAY_RE = re.compile(r"^(?P<y>\d{2})(?P<m>\d{2})(?P<d>\d{2})-")
_LONG_DAY_RE = re.compile(r"^(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})(?:[-_]|$)")

_DIGITS = frozenset("0123456789")

# A word for capitalization: a run of letters. Foundation's `capitalized` keeps a
# word whole across these marks (apostrophes and accents, measured, not guessed)
# and starts a new word after any other non-letter.
_WORD_JOINERS = "'^`\u2019\u02bc\u00b4"
_WORD_RE = re.compile(rf"[^\W\d_]+(?:[{re.escape(_WORD_JOINERS)}][^\W\d_]+)*")


@dataclass
class Turn:
    """One stretch of a transcript: a speaker run, or a single line without diarization."""

    ordinal: int
    speaker: str | None
    start: float
    end: float
    text: str


def folder_title(name: str) -> str:
    """Display title for a meeting folder name.

    The same rules as the app's `MeetingLoader.prettyTitle`, which still names
    folders when the app runs an older CLI; both are tested against the same cases.

      `260609-q2-sales-review`          -> `Q2 Sales Review`
      `260609-standup_1630`             -> `Standup`          (collision suffix)
      `260609-1053`                     -> `260609-1053`      (untitled: kept as is)
      `2026-06-09_1053_q2-sales-review` -> `Q2 Sales Review`  (legacy layout)
    """
    legacy = name.split("_", 2)
    if len(legacy) == 3 and legacy[2]:
        return _capitalize_words(legacy[2].replace("-", " "))

    body = name
    head, sep, suffix = body.rpartition("_")
    if sep and len(suffix) == 4 and _all_digits(suffix):
        body = head

    parts = body.split("-")
    if len(parts) < 2 or len(parts[0]) != 6 or not _all_digits(parts[0]):
        return name
    rest = parts[1:]
    # An untitled run is just a time, HHMM or HHMMSS. `260609-2026` could also be
    # a meeting titled "2026"; untitled runs are far more common.
    if len(rest) == 1 and len(rest[0]) in (4, 6) and _all_digits(rest[0]):
        return name
    return _capitalize_words(" ".join(rest))


def folder_day(name: str) -> date | None:
    """The meeting day at the start of a folder name, or None when there is none."""
    if m := _SHORT_DAY_RE.match(name):
        year = 2000 + int(m["y"])
    elif m := _LONG_DAY_RE.match(name):
        year = int(m["y"])
    else:
        return None
    try:
        return date(year, int(m["m"]), int(m["d"]))
    except ValueError:
        return None


def build_turns(result: TranscriptResult) -> list[Turn]:
    """Group segments into turns.

    With diarization a turn is a run of segments by one speaker. Without it every
    segment is its own turn, so each timestamped line can be played on its own.
    An end missing from the file (markdown keeps none) is the next turn's start,
    and the last turn ends at the transcript's duration.
    """
    groups: list[list[Segment]] = []
    for seg in result.segments:
        if not seg.text.strip():
            continue
        if result.has_speakers and groups and groups[-1][0].speaker == seg.speaker:
            groups[-1].append(seg)
        else:
            groups.append([seg])

    turns: list[Turn] = []
    for ordinal, group in enumerate(groups):
        turns.append(
            Turn(
                ordinal=ordinal,
                speaker=group[0].speaker,
                start=float(group[0].start),
                end=float(group[-1].end),
                text=" ".join(seg.text.strip() for seg in group),
            )
        )

    for turn, following in pairwise(turns):
        if turn.end <= turn.start:
            turn.end = following.start
    if turns and turns[-1].end <= turns[-1].start:
        turns[-1].end = max(turns[-1].start, result.duration)
    return turns


@dataclass
class _SpeakerTally:
    turns: int
    seconds: float
    longest: Turn


def speaker_stats(turns: list[Turn]) -> list[dict]:
    """Per speaker, in order of first appearance: turn count, seconds, longest turn.

    Seconds are approximate for markdown transcripts, whose turns end where the
    next one starts.
    """
    tallies: dict[str, _SpeakerTally] = {}
    for turn in turns:
        if turn.speaker is None:
            continue
        tally = tallies.setdefault(turn.speaker, _SpeakerTally(turns=0, seconds=0.0, longest=turn))
        tally.turns += 1
        tally.seconds += turn.end - turn.start
        if turn.end - turn.start > tally.longest.end - tally.longest.start:
            tally.longest = turn
    return [
        {"label": label, "turns": t.turns, "seconds": round(t.seconds, 1), "longest_turn": t.longest.ordinal}
        for label, t in tallies.items()
    ]


def meeting_detail(config: Config, directory: Path) -> dict:
    """Everything the app shows for one meeting folder."""
    result = _read_transcript(directory)
    turns = build_turns(result) if result else []
    return {
        "schema": SCHEMA_VERSION,
        "title": folder_title(directory.name),
        "language": (result.language or None) if result else None,
        "duration": _duration(result),
        "turns": [
            {"ordinal": t.ordinal, "speaker": t.speaker, "start": t.start, "end": t.end, "text": t.text} for t in turns
        ],
        "speakers": speaker_stats(turns),
        "status": _status(config, directory),
    }


def meeting_rows(config: Config) -> dict:
    """One row per meeting folder in the output directory, for the app's library.

    A folder is any non-hidden directory there, including ones holding only audio
    or only crash leftovers: the app decides what each status means. A missing
    output directory is an empty library, not an error; nothing has been
    recorded yet.
    """
    base = config.output.resolved_dir
    folders = sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith(".")) if base.is_dir() else []
    return {"schema": SCHEMA_VERSION, "meetings": [_row(config, folder) for folder in folders]}


def _row(config: Config, folder: Path) -> dict:
    result = _read_transcript(folder)
    day = folder_day(folder.name)
    return {
        "path": str(folder),
        "name_day": day.isoformat() if day else None,
        "created": _created(folder),
        "title": folder_title(folder.name),
        "duration": _duration(result),
        "speaker_count": len(speaker_stats(build_turns(result))) if result else 0,
        "status": _status(config, folder),
    }


def _created(folder: Path) -> str | None:
    """The folder's creation time as local ISO 8601, or None where the OS keeps none.

    Copying a folder (cp, ditto, rsync) resets it, which is why the day in the
    name comes first.
    """
    birth = getattr(folder.stat(), "st_birthtime", None)
    if birth is None:
        return None
    return datetime.fromtimestamp(birth).astimezone().isoformat(timespec="seconds")


def _read_transcript(directory: Path) -> TranscriptResult | None:
    """The folder's transcript, or None when there is none or it cannot be read back."""
    for name in _TRANSCRIPT_NAMES:
        path = directory / name
        if path.is_file():
            text = path.read_text()
            return parse_transcript_json(text) if path.suffix == ".json" else parse_transcript(text)
    return None


def _duration(result: TranscriptResult | None) -> float | None:
    """Seconds, or None when the transcript does not record it."""
    if result is None or result.duration <= 0:
        return None
    return result.duration


def _status(config: Config, directory: Path) -> dict:
    """What the folder holds: transcript, summary, audio and original-name copies."""
    has_transcript = any((directory / name).is_file() for name in _TRANSCRIPT_NAMES)
    if _find_summary(directory) is not None:
        summary = "present"
    elif config.summarization.enabled:
        summary = "missing"
    else:
        summary = "disabled"
    audio = find_meeting_audio(config, directory)
    return {
        "transcript": "present" if has_transcript else "missing",
        "summary": summary,
        "audio": str(audio) if audio else None,
        "orig": any((directory / name).is_file() for name in _ORIGINAL_NAMES),
    }


def _capitalize_words(text: str) -> str:
    """Upper-case the first letter of each word and lower-case the rest.

    Matches Foundation's `String.capitalized`, which the app uses: any non-letter
    starts a new word (`ai@strategy` -> `Ai@Strategy`, `time4work` -> `Time4Work`)
    except the apostrophes and accent marks in _WORD_JOINERS (`o'neil` -> `O'neil`,
    where str.title() gives `O'Neil`).
    """
    return _WORD_RE.sub(lambda m: m[0][:1].upper() + m[0][1:].lower(), text)


def _all_digits(text: str) -> bool:
    return bool(text) and all(ch in _DIGITS for ch in text)
