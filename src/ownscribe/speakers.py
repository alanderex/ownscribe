"""List and rename diarized speaker labels in saved transcripts.

Diarization emits anonymous labels (``SPEAKER_00``, ``SPEAKER_01``, …) that are
not stable across meetings, so naming happens per meeting after the fact. The
summarizer never sees these labels (it summarizes plain segment text), so
renaming is a pure rewrite of the transcript file — no re-summarization needed.

Works on both output formats: markdown (the default) and JSON.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

# Speaker header line written by output/markdown.py: ``**LABEL** [mm:ss]``.
# Anchored to line start so body lines (``[mm:ss] text``) never match.
_MD_SPEAKER_RE = re.compile(r"^\*\*(.+?)\*\* \[", re.MULTILINE)


def list_speakers_markdown(text: str) -> list[str]:
    """Return distinct speaker labels in a markdown transcript, in first-seen order."""
    seen: list[str] = []
    for match in _MD_SPEAKER_RE.finditer(text):
        label = match.group(1)
        if label not in seen:
            seen.append(label)
    return seen


def list_speakers_json(text: str) -> list[str]:
    """Return distinct speaker labels in a JSON transcript, in first-seen order."""
    data = json.loads(text)
    seen: list[str] = []
    for seg in data.get("segments", []):
        speaker = seg.get("speaker")
        if speaker and speaker not in seen:
            seen.append(speaker)
    return seen


def rename_markdown(text: str, mapping: dict[str, str]) -> str:
    """Rewrite speaker header labels in a markdown transcript."""

    def _repl(match: re.Match) -> str:
        label = match.group(1)
        return f"**{mapping.get(label, label)}** ["

    return _MD_SPEAKER_RE.sub(_repl, text)


def rename_json(text: str, mapping: dict[str, str]) -> str:
    """Rewrite speaker labels on segments and words in a JSON transcript."""
    data = json.loads(text)
    for seg in data.get("segments", []):
        if seg.get("speaker") in mapping:
            seg["speaker"] = mapping[seg["speaker"]]
        for word in seg.get("words", []):
            if word.get("speaker") in mapping:
                word["speaker"] = mapping[word["speaker"]]
    return json.dumps(data, indent=2, ensure_ascii=False)


def list_speakers(path: Path) -> list[str]:
    """List distinct speaker labels in a transcript file (format from suffix)."""
    text = path.read_text()
    if path.suffix.lower() == ".json":
        return list_speakers_json(text)
    return list_speakers_markdown(text)


def apply_rename(path: Path, mapping: dict[str, str]) -> int:
    """Apply a label->name mapping to a transcript file in place.

    Returns the number of distinct labels actually present and renamed.
    """
    text = path.read_text()
    if path.suffix.lower() == ".json":
        present = list_speakers_json(text)
        new_text = rename_json(text, mapping)
    else:
        present = list_speakers_markdown(text)
        new_text = rename_markdown(text, mapping)
    renamed = sum(1 for label in present if label in mapping)
    path.write_text(new_text)
    return renamed
