"""Tests for speaker label listing and renaming."""

from __future__ import annotations

import json

from ownscribe import speakers
from ownscribe.output.markdown import format_transcript


class TestMarkdown:
    def test_list(self, diarized_transcript):
        md = format_transcript(diarized_transcript)
        assert speakers.list_speakers_markdown(md) == ["SPEAKER_00", "SPEAKER_01"]

    def test_rename_all(self, diarized_transcript):
        md = format_transcript(diarized_transcript)
        out = speakers.rename_markdown(md, {"SPEAKER_00": "Anna", "SPEAKER_01": "Bob"})
        assert "**Anna**" in out
        assert "**Bob**" in out
        assert "SPEAKER_0" not in out
        assert speakers.list_speakers_markdown(out) == ["Anna", "Bob"]

    def test_rename_partial(self, diarized_transcript):
        md = format_transcript(diarized_transcript)
        out = speakers.rename_markdown(md, {"SPEAKER_00": "Anna"})
        assert "**Anna**" in out
        assert "**SPEAKER_01**" in out

    def test_body_mentions_untouched(self):
        md = "**SPEAKER_00** [00:00]\nSPEAKER_00 said hello\n[00:02] more\n"
        out = speakers.rename_markdown(md, {"SPEAKER_00": "Anna"})
        assert "**Anna** [00:00]" in out
        assert "SPEAKER_00 said hello" in out  # body text mention is not a header

    def test_language_header_not_a_speaker(self):
        md = "# Transcript\n\n**Language:** en  \n\n**SPEAKER_00** [00:00]\nHi\n"
        assert speakers.list_speakers_markdown(md) == ["SPEAKER_00"]


def _json_doc() -> str:
    return json.dumps(
        {
            "segments": [
                {
                    "text": "Hi",
                    "start": 0,
                    "end": 1,
                    "speaker": "SPEAKER_00",
                    "words": [{"text": "Hi", "start": 0, "end": 1, "speaker": "SPEAKER_00"}],
                },
                {"text": "Yo", "start": 1, "end": 2, "speaker": "SPEAKER_01", "words": []},
            ],
            "language": "en",
            "duration": 2,
        }
    )


class TestJson:
    def test_list(self):
        assert speakers.list_speakers_json(_json_doc()) == ["SPEAKER_00", "SPEAKER_01"]

    def test_rename(self):
        out = speakers.rename_json(_json_doc(), {"SPEAKER_00": "Anna"})
        data = json.loads(out)
        assert data["segments"][0]["speaker"] == "Anna"
        assert data["segments"][0]["words"][0]["speaker"] == "Anna"
        assert data["segments"][1]["speaker"] == "SPEAKER_01"


class TestMalformedJson:
    def test_array_json_raises_clear_error(self):
        import pytest

        with pytest.raises(ValueError, match="Expected a JSON object"):
            speakers.list_speakers_json("[1, 2, 3]")

    def test_rename_array_json_raises(self):
        import pytest

        with pytest.raises(ValueError, match="Expected a JSON object"):
            speakers.rename_json("[]", {"SPEAKER_00": "Anna"})


class TestApplyRename:
    def test_md_file_counts_only_present(self, tmp_path, diarized_transcript):
        p = tmp_path / "transcript.md"
        p.write_text(format_transcript(diarized_transcript))
        renamed = speakers.apply_rename(p, {"SPEAKER_00": "Anna", "SPEAKER_99": "Ghost"})
        assert renamed == 1  # SPEAKER_99 not present
        assert "**Anna**" in p.read_text()

    def test_json_file(self, tmp_path):
        p = tmp_path / "transcript.json"
        p.write_text(_json_doc())
        renamed = speakers.apply_rename(p, {"SPEAKER_00": "Anna", "SPEAKER_01": "Bob"})
        assert renamed == 2
        assert json.loads(p.read_text())["segments"][0]["speaker"] == "Anna"

    def test_list_dispatch_by_suffix(self, tmp_path, diarized_transcript):
        p = tmp_path / "transcript.md"
        p.write_text(format_transcript(diarized_transcript))
        assert speakers.list_speakers(p) == ["SPEAKER_00", "SPEAKER_01"]
