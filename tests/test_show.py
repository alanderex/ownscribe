"""Tests for `ownscribe show`: meeting folders described as JSON for front-ends."""

from __future__ import annotations

import json
from unittest import mock

import pytest
from click.testing import CliRunner

from ownscribe.cli import cli
from ownscribe.config import Config
from ownscribe.output.json_output import format_summary_json, format_transcript_json
from ownscribe.output.markdown import format_summary, format_transcript
from ownscribe.show import build_turns, folder_title, meeting_detail, speaker_stats
from ownscribe.transcription.models import Segment, TranscriptResult

# Shared with the app's prettyTitle tests (macapp/Tests/LogicTests): both
# implementations must name a folder the same way.
FOLDER_TITLES = [
    ("260609-q2-sales-review", "Q2 Sales Review"),
    ("260609-standup_1630", "Standup"),
    ("260609-budget-2026", "Budget 2026"),
    ("260609-1053", "260609-1053"),
    ("260609-105312", "260609-105312"),
    ("260609-2026", "260609-2026"),
    ("2026-06-09_1053_q2-sales-review", "Q2 Sales Review"),
    ("2026-06-18_1400", "2026-06-18_1400"),
    ("2026-06-16-su-screener", "2026-06-16-su-screener"),
    ("2026-06-17-Alexander W_german-startup", "2026-06-17-Alexander W_german-startup"),
    ("261007-ai@strategy", "Ai@strategy"),
    ("261015-HE", "He"),
    ("261001-1425-snyc-pycon", "1425 Snyc Pycon"),
    ("notes", "notes"),
]


@pytest.fixture
def meeting() -> TranscriptResult:
    """Two speakers; SPEAKER_00 opens with a three-segment run."""
    return TranscriptResult(
        segments=[
            Segment(text="Welcome everyone.", start=0.0, end=2.0, speaker="SPEAKER_00"),
            Segment(text="Today is about the budget.", start=2.0, end=5.0, speaker="SPEAKER_00"),
            Segment(text="And the hiring plan.", start=5.0, end=8.0, speaker="SPEAKER_00"),
            Segment(text="Sounds good.", start=8.0, end=9.0, speaker="SPEAKER_01"),
            Segment(text="Numbers first.", start=10.0, end=30.0, speaker="SPEAKER_00"),
        ],
        language="en",
        duration=40.0,
    )


@pytest.fixture
def config(tmp_path) -> Config:
    config = Config()
    config.output.dir = str(tmp_path / "notes")
    return config


def _folder(config: Config, name: str = "260101-budget-review"):
    folder = config.output.resolved_dir / name
    folder.mkdir(parents=True)
    return folder


class TestFolderTitle:
    @pytest.mark.parametrize(("name", "title"), FOLDER_TITLES)
    def test_title(self, name, title):
        assert folder_title(name) == title


class TestBuildTurns:
    def test_a_turn_is_a_speaker_run(self, meeting):
        turns = build_turns(meeting)

        assert [t.speaker for t in turns] == ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"]
        assert turns[0].text == "Welcome everyone. Today is about the budget. And the hiring plan."
        assert [t.ordinal for t in turns] == [0, 1, 2]

    def test_json_keeps_real_end_times(self, meeting):
        turns = build_turns(meeting)

        assert [(t.start, t.end) for t in turns] == [(0.0, 8.0), (8.0, 9.0), (10.0, 30.0)]

    def test_markdown_ends_at_next_start_and_duration(self, meeting):
        from ownscribe.output.markdown import parse_transcript

        parsed = parse_transcript(format_transcript(meeting))
        assert parsed is not None
        turns = build_turns(parsed)

        assert [(t.start, t.end) for t in turns] == [(0.0, 8.0), (8.0, 10.0), (10.0, 40.0)]

    def test_without_speakers_each_line_is_a_turn(self, sample_transcript):
        turns = build_turns(sample_transcript)

        assert [t.text for t in turns] == ["Hello world.", "How are you?"]
        assert all(t.speaker is None for t in turns)

    def test_last_turn_without_duration_is_empty_not_negative(self):
        result = TranscriptResult(segments=[Segment(text="Hi.", start=5.0, end=0.0)])

        (turn,) = build_turns(result)

        assert turn.end == 5.0


class TestSpeakerStats:
    def test_counts_seconds_and_longest_turn(self, meeting):
        stats = speaker_stats(build_turns(meeting))

        assert stats == [
            {"label": "SPEAKER_00", "turns": 2, "seconds": 28.0, "longest_turn": 2},
            {"label": "SPEAKER_01", "turns": 1, "seconds": 1.0, "longest_turn": 1},
        ]

    def test_no_speakers(self, sample_transcript):
        assert speaker_stats(build_turns(sample_transcript)) == []


class TestMeetingDetail:
    def test_markdown_meeting(self, config, meeting):
        folder = _folder(config)
        (folder / "transcript.md").write_text(format_transcript(meeting))
        (folder / "summary.md").write_text(format_summary("We agreed."))
        (folder / "recording.wav").write_bytes(b"")

        detail = meeting_detail(config, folder)

        assert detail["schema"] == 1
        assert detail["title"] == "Budget Review"
        assert detail["language"] == "en"
        assert detail["duration"] == 40.0
        assert len(detail["turns"]) == 3
        assert detail["turns"][1] == {
            "ordinal": 1,
            "speaker": "SPEAKER_01",
            "start": 8.0,
            "end": 10.0,
            "text": "Sounds good.",
        }
        assert [s["label"] for s in detail["speakers"]] == ["SPEAKER_00", "SPEAKER_01"]
        assert detail["status"] == {
            "transcript": "present",
            "summary": "present",
            "audio": str(folder / "recording.wav"),
            "orig": False,
        }

    def test_json_wins_over_markdown(self, config, meeting):
        folder = _folder(config)
        (folder / "transcript.md").write_text("# Transcript\n\n[00:00] Stale markdown.\n")
        (folder / "transcript.json").write_text(format_transcript_json(meeting))
        (folder / "summary.json").write_text(format_summary_json("We agreed."))

        detail = meeting_detail(config, folder)

        assert detail["turns"][0]["text"].startswith("Welcome everyone.")
        assert detail["turns"][1]["end"] == 9.0
        assert detail["status"]["summary"] == "present"

    def test_audio_from_a_separate_audio_dir(self, config, meeting, tmp_path):
        config.output.audio_dir = str(tmp_path / "audio")
        folder = _folder(config)
        (folder / "transcript.md").write_text(format_transcript(meeting))
        audio = tmp_path / "audio" / folder.name
        audio.mkdir(parents=True)
        (audio / "recording.wav").write_bytes(b"")

        assert meeting_detail(config, folder)["status"]["audio"] == str(audio / "recording.wav")

    def test_summary_missing_or_disabled(self, config, meeting):
        folder = _folder(config)
        (folder / "transcript.md").write_text(format_transcript(meeting))

        assert meeting_detail(config, folder)["status"]["summary"] == "missing"
        config.summarization.enabled = False
        assert meeting_detail(config, folder)["status"]["summary"] == "disabled"

    def test_original_copy_is_reported(self, config, meeting):
        folder = _folder(config)
        (folder / "transcript.md").write_text(format_transcript(meeting))
        (folder / "transcript.md.orig").write_text(format_transcript(meeting))

        assert meeting_detail(config, folder)["status"]["orig"] is True

    def test_folder_with_only_audio(self, config):
        folder = _folder(config, "260101-1400")
        (folder / "recording.wav").write_bytes(b"")
        (folder / "recording.wav.mic.tmp.wav").write_bytes(b"")

        detail = meeting_detail(config, folder)

        assert detail["turns"] == []
        assert detail["speakers"] == []
        assert detail["duration"] is None
        assert detail["language"] is None
        assert detail["status"]["transcript"] == "missing"
        assert detail["status"]["audio"] == str(folder / "recording.wav")

    def test_crash_leftovers_are_no_audio(self, config):
        folder = _folder(config, "260101-1400")
        (folder / "recording.wav.mic.tmp.wav").write_bytes(b"")
        (folder / "recording.wav.sys.tmp.wav").write_bytes(b"")

        assert meeting_detail(config, folder)["status"]["audio"] is None


class TestShowCommand:
    def test_prints_the_detail_as_json(self, config, meeting):
        folder = _folder(config)
        (folder / "transcript.md").write_text(format_transcript(meeting))

        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            result = CliRunner().invoke(cli, ["show", str(folder), "--json"])

        assert result.exit_code == 0, result.output
        payload = json.loads(result.output)
        assert payload["title"] == "Budget Review"
        assert len(payload["turns"]) == 3

    def test_requires_json(self, config):
        folder = _folder(config)

        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            result = CliRunner().invoke(cli, ["show", str(folder)])

        assert result.exit_code == 2
        assert "pass --json" in result.output

    def test_rejects_a_missing_folder(self, config, tmp_path):
        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            result = CliRunner().invoke(cli, ["show", str(tmp_path / "nope"), "--json"])

        assert result.exit_code == 2
