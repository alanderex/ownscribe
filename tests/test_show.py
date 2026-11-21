"""Tests for `ownscribe show`: meeting folders described as JSON for front-ends."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import date
from unittest import mock

import pytest
from click.testing import CliRunner

from ownscribe.cli import cli
from ownscribe.config import Config
from ownscribe.output.json_output import format_summary_json, format_transcript_json
from ownscribe.output.markdown import format_summary, format_transcript
from ownscribe.show import build_turns, folder_day, folder_title, meeting_detail, meeting_rows, speaker_stats
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


class TestFolderDay:
    @pytest.mark.parametrize(
        ("name", "day"),
        [
            ("260101-budget-review", date(2026, 1, 1)),
            ("260902-060902-heidelberg", date(2026, 9, 2)),
            ("2026-06-16-su-screener", date(2026, 6, 16)),
            ("2026-06-18_1400", date(2026, 6, 18)),
            ("2026-06-09_1053_q2-sales-review", date(2026, 6, 9)),
            ("2026-06-18", date(2026, 6, 18)),
            ("261399-not-a-date", None),
            ("20260616-eight-digits", None),
            ("260101", None),
            ("notes", None),
        ],
    )
    def test_day(self, name, day):
        assert folder_day(name) == day


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


class TestMeetingRows:
    def test_one_row_per_meeting_folder(self, config, meeting):
        titled = _folder(config, "260102-budget-review")
        (titled / "transcript.md").write_text(format_transcript(meeting))
        (titled / "summary.md").write_text(format_summary("We agreed."))
        untitled = _folder(config, "260101-1400")
        (untitled / "recording.wav").write_bytes(b"")
        _folder(config, ".hidden")
        (config.output.resolved_dir / "stray.txt").write_text("not a meeting")

        payload = meeting_rows(config)

        assert payload["schema"] == 1
        rows = payload["meetings"]
        assert [r["path"] for r in rows] == [str(untitled), str(titled)]
        first, second = rows
        assert first["name_day"] == "2026-01-01"
        assert first["title"] == "260101-1400"
        assert first["duration"] is None
        assert first["speaker_count"] == 0
        assert first["status"]["transcript"] == "missing"
        assert first["status"]["audio"] == str(untitled / "recording.wav")
        assert second["title"] == "Budget Review"
        assert second["duration"] == 40.0
        assert second["speaker_count"] == 2
        assert second["status"]["summary"] == "present"
        assert first["created"] is not None and first["created"][:4].isdigit()

    def test_missing_output_dir_is_an_empty_library(self, config):
        assert meeting_rows(config) == {"schema": 1, "meetings": []}

    def test_two_hundred_hour_long_meetings_list_fast(self, config):
        """The plan's budget for `show --list`: 300 ms for 200 folders."""
        segments = []
        for i in range(700):  # about one hour of whisper segments
            speaker = f"SPEAKER_0{(i // 4) % 3}"  # runs of four, three speakers
            segments.append(
                Segment(
                    text=f"Sentence number {i} about the quarterly plan.",
                    start=i * 5.0,
                    end=i * 5.0 + 4.0,
                    speaker=speaker,
                )
            )
        transcript = format_transcript(TranscriptResult(segments=segments, language="en", duration=3500.0))
        for n in range(200):
            folder = _folder(config, f"26{n // 28 + 1:02d}{n % 28 + 1:02d}-meeting-{n}")
            (folder / "transcript.md").write_text(transcript)
            (folder / "summary.md").write_text(format_summary("Summary."))
            (folder / "recording.wav").write_bytes(b"")

        started = time.perf_counter()
        rows = meeting_rows(config)["meetings"]
        elapsed = time.perf_counter() - started

        assert len(rows) == 200
        assert all(r["speaker_count"] == 3 for r in rows)
        assert elapsed < 0.3, f"show --list took {elapsed * 1000:.0f} ms for 200 folders"

    def test_does_not_import_the_ml_stacks(self, tmp_path):
        """The app runs `show --list` on every refresh; it must stay a light process."""
        notes = tmp_path / "notes"
        (notes / "260101-standup").mkdir(parents=True)
        config_file = tmp_path / "config.toml"
        config_file.write_text(f'[output]\ndir = "{notes}"\n')
        code = f"""
import sys
from pathlib import Path
import ownscribe.config as cfg
cfg.CONFIG_PATH = Path({str(config_file)!r})
from click.testing import CliRunner
from ownscribe.cli import cli
result = CliRunner().invoke(cli, ["show", "--list", "--json"])
assert result.exit_code == 0, result.output
heavy = {{"torch", "whisperx", "pyannote", "llama_cpp", "openai", "ollama"}}
backends = {{
    "ownscribe.transcription.whisperx_transcriber",
    "ownscribe.summarization.llama_cpp_summarizer",
    "ownscribe.summarization.ollama_summarizer",
    "ownscribe.summarization.openai_summarizer",
}}
print(sorted(m for m in sys.modules if m.split(".")[0] in heavy or m in backends))
"""
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
        assert out.stdout.strip() == "[]"


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

    def test_list_prints_rows(self, config, meeting):
        folder = _folder(config)
        (folder / "transcript.md").write_text(format_transcript(meeting))

        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            result = CliRunner().invoke(cli, ["show", "--list", "--json"])

        assert result.exit_code == 0, result.output
        assert [r["title"] for r in json.loads(result.output)["meetings"]] == ["Budget Review"]

    def test_list_and_directory_are_exclusive(self, config):
        folder = _folder(config)

        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            result = CliRunner().invoke(cli, ["show", str(folder), "--list", "--json"])

        assert result.exit_code == 2
        assert "not both" in result.output

    def test_needs_a_directory_or_list(self, config):
        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            result = CliRunner().invoke(cli, ["show", "--json"])

        assert result.exit_code == 2
        assert "DIRECTORY" in result.output
