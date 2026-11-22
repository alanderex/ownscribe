"""A meeting's transcript file, read the way `show` and the speaker editor both see it.

`show DIR --json` numbers the transcript's segments and reports a revision; a later
`edit-speakers --assign` names segments by those numbers and passes the revision
back. Both read the file through here, so the numbering cannot drift between them.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from ownscribe.meeting_files import TRANSCRIPT_NAMES
from ownscribe.output.json_output import dump_json, parse_transcript_json
from ownscribe.output.markdown import format_transcript, parse_transcript
from ownscribe.transcription.models import TranscriptResult


@dataclass(frozen=True)
class TranscriptFile:
    """The transcript's path, exact bytes, and parsed form (None if it does not parse)."""

    path: Path
    raw: bytes
    result: TranscriptResult | None

    @property
    def text(self) -> str:
        return self.raw.decode("utf-8")

    @property
    def is_json(self) -> bool:
        return self.path.suffix == ".json"

    @property
    def revision(self) -> str:
        """sha256 of the file's bytes: any change to the file changes it."""
        return hashlib.sha256(self.raw).hexdigest()

    @property
    def standard_layout(self) -> bool:
        """Whether writing the file again in ownscribe's layout would reproduce it exactly.

        Moving a line rewrites the whole transcript in that layout; for any other file
        (an older version's layout, a hand edit) the first move changes more than the
        speakers, which the app says before it saves.
        """
        if self.is_json:
            try:
                return dump_json(json.loads(self.text)) == self.text
            except ValueError:
                return False
        return self.result is not None and format_transcript(self.result) == self.text


def read_transcript(folder: Path) -> TranscriptFile | None:
    """The folder's transcript (transcript.json wins over transcript.md), or None."""
    for name in TRANSCRIPT_NAMES:
        path = folder / name
        if path.is_file():
            raw = path.read_bytes()
            text = raw.decode("utf-8")
            result = parse_transcript_json(text) if path.suffix == ".json" else parse_transcript(text)
            return TranscriptFile(path=path, raw=raw, result=result)
    return None
