"""Read-only descriptions of meeting folders, as data for front-ends.

`ownscribe show DIR --json` describes one meeting; `ownscribe show --list --json`
lists every meeting folder in the output directory. The menu-bar app reads these
instead of parsing transcripts itself, so the transcript formats stay known to
Python alone.

Nothing here may import the transcription or summarization stacks: the app runs
`show --list` on every library refresh.
"""

from __future__ import annotations

from dataclasses import dataclass
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

_DIGITS = frozenset("0123456789")


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
    """Upper-case each space-separated word's first letter, lower-case the rest.

    Matches Foundation's `String.capitalized`, which the app uses: words are split
    on whitespace only, so `q2` stays `Q2` and `ai@strategy` becomes `Ai@strategy`
    (str.title() would give `Ai@Strategy`, and `2Nd` for `2nd`).
    """
    return " ".join(word[:1].upper() + word[1:].lower() for word in text.split(" "))


def _all_digits(text: str) -> bool:
    return bool(text) and all(ch in _DIGITS for ch in text)
