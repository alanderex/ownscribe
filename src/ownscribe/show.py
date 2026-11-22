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
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import date, datetime
from itertools import pairwise
from pathlib import Path
from typing import Protocol

from ownscribe.config import Config
from ownscribe.locks import probe
from ownscribe.meeting_files import ORIGINAL_NAMES, TRANSCRIPT_NAMES
from ownscribe.meeting_meta import summary_is_stale
from ownscribe.pipeline import _find_summary, find_meeting_audio
from ownscribe.transcript_io import read_transcript
from ownscribe.transcription.models import Segment, TranscriptResult

#: Bumped when a field changes meaning or disappears; new fields do not bump it.
SCHEMA_VERSION = 1

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


class _Span(Protocol):
    start: float
    end: float


@dataclass
class Line:
    """One timestamped line of a turn: a segment, numbered by its index in the parsed
    transcript, which is how `edit-speakers --assign` names it."""

    index: int
    start: float
    end: float
    text: str


@dataclass
class Turn:
    """One stretch of a transcript: a speaker run, or a single line without diarization."""

    ordinal: int
    speaker: str | None
    start: float
    end: float
    text: str
    lines: list[Line] = field(default_factory=list)


def folder_title(name: str) -> str:
    """Display title for a meeting folder name.

    The same rules as the app's `FolderName.title` (macapp/Sources/Logic), which
    still names folders when the app runs an older CLI; both are tested against
    the same cases.

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
    and the last turn ends at the transcript's duration; the same holds for lines.
    """
    has_speakers = result.has_speakers  # a scan of all segments, so once, not per segment
    groups: list[list[tuple[int, Segment]]] = []
    for index, seg in enumerate(result.segments):
        if not seg.text.strip():
            continue
        if has_speakers and groups and groups[-1][0][1].speaker == seg.speaker:
            groups[-1].append((index, seg))
        else:
            groups.append([(index, seg)])

    turns: list[Turn] = []
    for ordinal, group in enumerate(groups):
        first, last = group[0][1], group[-1][1]
        turns.append(
            Turn(
                ordinal=ordinal,
                speaker=first.speaker,
                start=float(first.start),
                end=float(last.end),
                text=" ".join(seg.text.strip() for _, seg in group),
                lines=[Line(index, float(seg.start), float(seg.end), seg.text.strip()) for index, seg in group],
            )
        )

    _close_gaps(turns, result.duration)
    _close_gaps([line for turn in turns for line in turn.lines], result.duration)
    return turns


def _close_gaps(spans: Sequence[_Span], duration: float) -> None:
    """Give each span without an end the next span's start; the last ends at `duration`."""
    for span, following in pairwise(spans):
        if span.end <= span.start:
            span.end = following.start
    if spans and spans[-1].end <= spans[-1].start:
        spans[-1].end = max(spans[-1].start, duration)


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
    """Everything the app shows for one meeting folder.

    `revision` identifies the transcript file's exact contents; `edit-speakers
    --assign` takes it back so line numbers never apply to a file that has changed.
    `standard_layout` says whether moving a line would leave the rest of the file as
    it is (see TranscriptFile.standard_layout).
    """
    transcript = read_transcript(directory)
    result = transcript.result if transcript else None
    turns = build_turns(result) if result else []
    return {
        "schema": SCHEMA_VERSION,
        "title": folder_title(directory.name),
        "language": (result.language or None) if result else None,
        "duration": _duration(result),
        "revision": transcript.revision if transcript else None,
        "standard_layout": transcript.standard_layout if transcript else None,
        "turns": [_turn_json(turn) for turn in turns],
        "speakers": speaker_stats(turns),
        "status": _status(config, directory),
    }


def _turn_json(turn: Turn) -> dict:
    return {
        "ordinal": turn.ordinal,
        "speaker": turn.speaker,
        "start": turn.start,
        "end": turn.end,
        "text": turn.text,
        "segments": [
            {"index": line.index, "start": line.start, "end": line.end, "text": line.text} for line in turn.lines
        ],
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
    transcript = read_transcript(folder)
    result = transcript.result if transcript else None
    speakers = _speaker_labels(result)
    day = folder_day(folder.name)
    return {
        "path": str(folder),
        "name_day": day.isoformat() if day else None,
        "created": _created(folder),
        "title": folder_title(folder.name),
        "duration": _duration(result),
        "speaker_count": len(speakers),
        "speakers": speakers,
        "status": _status(config, folder),
    }


def _speaker_labels(result: TranscriptResult | None) -> list[str]:
    """The speakers `speaker_stats(build_turns(result))` lists, in the same order, without
    building turns.

    A speaker counts once a segment with text is theirs, the rule build_turns
    applies; without diarization every speaker is None and none count. A library
    row needs only the names (the app offers them when naming speakers elsewhere),
    and `show --list` reads every transcript on each refresh, so it skips joining
    the turn texts.
    """
    if result is None:
        return []
    labels = (seg.speaker for seg in result.segments if seg.speaker is not None and seg.text.strip())
    return list(dict.fromkeys(labels))


def _created(folder: Path) -> str | None:
    """The folder's creation time as local ISO 8601, or None where the OS keeps none.

    Copying a folder (cp, ditto, rsync) resets it, which is why the day in the
    name comes first.
    """
    birth = getattr(folder.stat(), "st_birthtime", None)
    if birth is None:
        return None
    return datetime.fromtimestamp(birth).astimezone().isoformat(timespec="seconds")


def _duration(result: TranscriptResult | None) -> float | None:
    """Seconds, or None when the transcript does not record it."""
    if result is None or result.duration <= 0:
        return None
    return result.duration


def _status(config: Config, directory: Path) -> dict:
    """What the folder holds (transcript, summary, audio, original-name copies) and
    whether a process is working on it.

    `busy` is true, false, or "unknown" on a volume where locks cannot be read;
    `holder_pid` names the process holding the folder's lock.
    """
    has_transcript = any((directory / name).is_file() for name in TRANSCRIPT_NAMES)
    if _find_summary(directory) is not None:
        summary = "present"
    elif config.summarization.enabled:
        summary = "missing"
    else:
        summary = "disabled"
    audio = find_meeting_audio(config, directory)
    lock = probe(directory)
    return {
        "transcript": "present" if has_transcript else "missing",
        "summary": summary,
        "audio": str(audio) if audio else None,
        "orig": any((directory / name).is_file() for name in ORIGINAL_NAMES),
        "busy": lock.busy,
        "holder_pid": lock.holder_pid,
        "summary_stale": summary_is_stale(directory),
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
