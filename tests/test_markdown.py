"""Tests for markdown output formatter."""

import pytest

from ownscribe.output.json_output import format_transcript_json
from ownscribe.output.markdown import (
    _format_time,
    format_summary,
    format_transcript,
    parse_transcript,
)
from ownscribe.pipeline import _load_transcript_text
from ownscribe.transcription.models import Segment, TranscriptResult


@pytest.fixture
def speaker_runs() -> TranscriptResult:
    """Diarized, with consecutive segments from one speaker.

    format_transcript writes a header only at a speaker change, so the second and
    third segments come out as bare `[mm:ss] text` continuation lines.
    """
    return TranscriptResult(
        segments=[
            Segment(text="Welcome everyone.", start=0.0, end=2.0, speaker="SPEAKER_00"),
            Segment(text="Today is about the budget.", start=2.0, end=5.0, speaker="SPEAKER_00"),
            Segment(text="And the hiring plan.", start=5.0, end=8.0, speaker="SPEAKER_00"),
            Segment(text="Sounds good.", start=8.0, end=9.5, speaker="SPEAKER_01"),
            Segment(text="I have numbers.", start=9.5, end=12.0, speaker="SPEAKER_01"),
        ],
        language="en",
        duration=754.0,
    )


class TestFormatTime:
    def test_zero_seconds(self):
        assert _format_time(0) == "00:00"

    def test_65_seconds(self):
        assert _format_time(65) == "01:05"

    def test_3661_seconds(self):
        assert _format_time(3661) == "01:01:01"

    def test_exact_hour(self):
        assert _format_time(3600) == "01:00:00"


class TestFormatTranscript:
    def test_without_speakers(self, sample_transcript):
        output = format_transcript(sample_transcript)
        assert output.startswith("# Transcript\n")
        assert "**Language:** en" in output
        assert "[00:00] Hello world." in output
        assert "[00:01] How are you?" in output

    def test_with_speakers(self, diarized_transcript):
        output = format_transcript(diarized_transcript)
        assert "**SPEAKER_00**" in output
        assert "**SPEAKER_01**" in output
        assert "Hi, let's get started." in output


class TestParseTranscript:
    """format_transcript's inverse, so resume/summarize never feed the LLM markdown."""

    def test_round_trip_without_speakers(self, sample_transcript):
        parsed = parse_transcript(format_transcript(sample_transcript))

        assert parsed is not None
        assert [seg.text for seg in parsed.segments] == ["Hello world.", "How are you?"]
        assert parsed.language == "en"

    def test_round_trip_with_speakers(self, diarized_transcript):
        parsed = parse_transcript(format_transcript(diarized_transcript))

        assert parsed is not None
        assert parsed.speaker_text == diarized_transcript.speaker_text

    def test_drops_timestamps_and_heading(self, sample_transcript):
        parsed = parse_transcript(format_transcript(sample_transcript))

        assert parsed is not None
        assert "[00:00]" not in parsed.speaker_text
        assert "# Transcript" not in parsed.speaker_text
        assert "**Duration:**" not in parsed.speaker_text

    def test_parses_hour_long_timestamps(self):
        parsed = parse_transcript("# Transcript\n\n[01:02:03] Still going.\n")

        assert parsed is not None
        assert parsed.segments[0].start == 3723
        assert parsed.segments[0].text == "Still going."

    def test_returns_none_for_plain_text(self):
        assert parse_transcript("") is None
        assert parse_transcript("# Transcript\n\n**Duration:** 00:10\n") is None

    def test_continuation_lines_keep_the_speaker(self, speaker_runs):
        parsed = parse_transcript(format_transcript(speaker_runs))

        assert parsed is not None
        assert [seg.speaker for seg in parsed.segments] == [seg.speaker for seg in speaker_runs.segments]
        # Markdown stamps are whole seconds.
        assert [seg.start for seg in parsed.segments] == [int(seg.start) for seg in speaker_runs.segments]
        assert parsed.speaker_text == speaker_runs.speaker_text

    def test_keeps_the_duration(self, speaker_runs):
        parsed = parse_transcript(format_transcript(speaker_runs))

        assert parsed is not None
        assert parsed.duration == 754.0

    def test_keeps_an_hour_long_duration(self):
        parsed = parse_transcript("# Transcript\n\n**Duration:** 01:02:03  \n\n[00:00] Hi.\n")

        assert parsed is not None
        assert parsed.duration == 3723.0

    def test_without_speakers_lines_stay_speakerless(self, sample_transcript):
        parsed = parse_transcript(format_transcript(sample_transcript))

        assert parsed is not None
        assert all(seg.speaker is None for seg in parsed.segments)


class TestResumeText:
    """What resume/summarize feed the summarizer from a saved transcript."""

    @pytest.mark.parametrize(
        ("name", "formatter"),
        [("transcript.md", format_transcript), ("transcript.json", format_transcript_json)],
    )
    def test_no_unknown_speaker_for_continuation_lines(self, tmp_path, speaker_runs, name, formatter):
        path = tmp_path / name
        path.write_text(formatter(speaker_runs))

        text = _load_transcript_text(path)

        assert "Unknown:" not in text
        assert text == speaker_runs.speaker_text


class TestFormatSummary:
    def test_wraps_text(self):
        output = format_summary("This is the summary.")
        assert output.startswith("# Meeting Summary\n")
        assert "This is the summary." in output

    def test_strips_whitespace(self):
        output = format_summary("  extra spaces  ")
        assert "extra spaces" in output
        assert "  extra" not in output
