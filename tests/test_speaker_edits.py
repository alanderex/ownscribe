"""Tests for `ownscribe edit-speakers`: renames and merges across transcript and summary."""

from __future__ import annotations

import json
from unittest import mock

import click
import pytest
from click.testing import CliRunner

from ownscribe.cli import cli
from ownscribe.config import Config
from ownscribe.locks import FolderBusyError
from ownscribe.meeting_meta import summary_is_stale
from ownscribe.output.json_output import format_summary_json, format_transcript_json
from ownscribe.output.markdown import format_summary, format_transcript
from ownscribe.show import build_turns
from ownscribe.speaker_edits import (
    TranscriptChangedError,
    check_name,
    edit_speakers,
    rename_words,
    revert_speaker_edits,
)
from ownscribe.transcript_io import read_transcript
from ownscribe.transcription.models import Segment, TranscriptResult, Word

SUMMARY = "SPEAKER_1 agreed with SPEAKER_10. Ask SPEAKER_1 about SPEAKER_1's budget."


def _meeting() -> TranscriptResult:
    return TranscriptResult(
        segments=[
            Segment(text="Welcome, SPEAKER_10 joins later.", start=0.0, end=2.0, speaker="SPEAKER_1"),
            Segment(text="Thanks.", start=2.0, end=3.0, speaker="SPEAKER_10"),
            Segment(text="Budget next.", start=3.0, end=5.0, speaker="SPEAKER_1"),
        ],
        language="en",
        duration=5.0,
    )


@pytest.fixture
def markdown_folder(tmp_path):
    folder = tmp_path / "260101-budget-review"
    folder.mkdir()
    (folder / "transcript.md").write_text(format_transcript(_meeting()))
    (folder / "summary.md").write_text(format_summary(SUMMARY))
    return folder


@pytest.fixture
def json_folder(tmp_path):
    folder = tmp_path / "260102-sync"
    folder.mkdir()
    meeting = _meeting()
    meeting.segments[0].words = [Word(text="Welcome,", start=0.0, end=0.5, speaker="SPEAKER_1")]
    (folder / "transcript.json").write_text(format_transcript_json(meeting))
    (folder / "summary.json").write_text(format_summary_json(SUMMARY))
    return folder


def _invoke(*args: str):
    with mock.patch("ownscribe.cli.Config.load", return_value=Config()):
        return CliRunner().invoke(cli, ["edit-speakers", *args])


class TestRenameWords:
    def test_whole_words_only(self):
        assert rename_words("SPEAKER_1 and SPEAKER_10", {"SPEAKER_1": "Anna"}) == "Anna and SPEAKER_10"

    def test_a_name_inside_a_longer_word_stays(self):
        assert rename_words("Anna met Annabelle", {"Anna": "Ben"}) == "Ben met Annabelle"

    def test_longer_labels_win(self):
        assert rename_words("Anna Lee and Anna", {"Anna": "A", "Anna Lee": "AL"}) == "AL and A"

    def test_two_names_swap(self):
        assert rename_words("Anna thanked Ben", {"Anna": "Ben", "Ben": "Anna"}) == "Ben thanked Anna"

    def test_backslashes_and_dollars_stay_literal(self):
        assert rename_words("SPEAKER_00 spoke", {"SPEAKER_00": r"C:\Users $1 \g<0>"}) == r"C:\Users $1 \g<0> spoke"

    def test_no_mapping_changes_nothing(self):
        assert rename_words("SPEAKER_00", {}) == "SPEAKER_00"


class TestCheckName:
    @pytest.mark.parametrize("name", ["", "   ", "A*nna", "Anna [PM]", "Anna\nLee", "Language: de", "Duration: x"])
    def test_names_a_transcript_cannot_hold_are_refused(self, name):
        with pytest.raises(click.ClickException):
            check_name(name)

    def test_a_name_is_trimmed(self):
        assert check_name("  Anna Lee  ") == "Anna Lee"


class TestRenameSpeakers:
    def test_markdown_transcript_changes_only_its_headers(self, markdown_folder):
        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna"})

        transcript = (markdown_folder / "transcript.md").read_text()
        assert "**Anna** [00:00]" in transcript
        assert "**SPEAKER_10** [00:02]" in transcript
        assert "Welcome, SPEAKER_10 joins later." in transcript  # spoken text is untouched

    def test_summary_changes_wherever_a_label_is_a_word(self, markdown_folder):
        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna", "SPEAKER_10": "Ben"})

        assert (markdown_folder / "summary.md").read_text() == format_summary(
            "Anna agreed with Ben. Ask Anna about Anna's budget."
        )

    def test_two_labels_mapped_to_one_name_merge(self, markdown_folder):
        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna", "SPEAKER_10": "Anna"})

        transcript = (markdown_folder / "transcript.md").read_text()
        assert "SPEAKER_1" not in transcript.replace("SPEAKER_10 joins", "")
        assert transcript.count("**Anna**") == 3

    def test_json_files_change_speakers_and_words_and_stay_json(self, json_folder):
        edit_speakers(json_folder, renames={"SPEAKER_1": "Anna"})

        transcript = json.loads((json_folder / "transcript.json").read_text())
        assert [seg["speaker"] for seg in transcript["segments"]] == ["Anna", "SPEAKER_10", "Anna"]
        assert transcript["segments"][0]["words"][0]["speaker"] == "Anna"
        summary = json.loads((json_folder / "summary.json").read_text())
        assert summary == {"summary": "Anna agreed with SPEAKER_10. Ask Anna about Anna's budget."}

    def test_returns_the_files_it_changed(self, markdown_folder):
        changed = edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna"})

        assert changed == [markdown_folder / "transcript.md", markdown_folder / "summary.md"]

    def test_an_unknown_label_is_refused_and_nothing_is_written(self, markdown_folder):
        before = (markdown_folder / "transcript.md").read_bytes()

        with pytest.raises(click.ClickException, match="SPEAKER_9"):
            edit_speakers(markdown_folder, renames={"SPEAKER_9": "Anna"})

        assert (markdown_folder / "transcript.md").read_bytes() == before
        assert not (markdown_folder / "transcript.md.orig").exists()

    def test_a_folder_without_a_transcript_is_refused(self, tmp_path):
        with pytest.raises(click.ClickException, match="No transcript"):
            edit_speakers(tmp_path, renames={"SPEAKER_1": "Anna"})

    def test_a_folder_another_process_holds_is_refused(self, markdown_folder, hold_folder_lock):
        with hold_folder_lock(markdown_folder), pytest.raises(FolderBusyError):
            edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna"})


class TestOriginals:
    def test_the_first_edit_keeps_a_copy_of_each_changed_file(self, markdown_folder):
        transcript = (markdown_folder / "transcript.md").read_bytes()
        summary = (markdown_folder / "summary.md").read_bytes()

        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna"})

        assert (markdown_folder / "transcript.md.orig").read_bytes() == transcript
        assert (markdown_folder / "summary.md.orig").read_bytes() == summary

    def test_later_edits_keep_the_first_copy(self, markdown_folder):
        transcript = (markdown_folder / "transcript.md").read_bytes()

        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna"})
        edit_speakers(markdown_folder, renames={"Anna": "Ann"})

        assert (markdown_folder / "transcript.md.orig").read_bytes() == transcript

    def test_revert_restores_every_file_byte_for_byte(self, markdown_folder):
        transcript = (markdown_folder / "transcript.md").read_bytes()
        summary = (markdown_folder / "summary.md").read_bytes()
        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna", "SPEAKER_10": "Anna"})
        edit_speakers(markdown_folder, renames={"Anna": "Ben"})

        restored = revert_speaker_edits(markdown_folder)

        assert restored == [markdown_folder / "transcript.md", markdown_folder / "summary.md"]
        assert (markdown_folder / "transcript.md").read_bytes() == transcript
        assert (markdown_folder / "summary.md").read_bytes() == summary
        assert not list(markdown_folder.glob("*.orig"))

    def test_revert_forgets_what_the_replaced_summary_was_written_with(self, markdown_folder):
        from ownscribe.meeting_meta import read_meta, record_summary

        edit_speakers(markdown_folder, renames={"SPEAKER_1": "Anna"})
        record_summary(markdown_folder, backend="omlx", model="m", template="meeting", instructions="x")
        revert_speaker_edits(markdown_folder)
        assert "summary_request" not in read_meta(markdown_folder)

    def test_revert_without_an_edit_is_refused(self, markdown_folder):
        with pytest.raises(click.ClickException, match="nothing to restore"):
            revert_speaker_edits(markdown_folder)


class TestCommand:
    def test_renames_and_reports_the_files(self, markdown_folder):
        result = _invoke(str(markdown_folder), "--map", "SPEAKER_1=Anna")

        assert result.exit_code == 0, result.output
        assert "transcript.md, summary.md" in result.output

    def test_reverts(self, markdown_folder):
        _invoke(str(markdown_folder), "--map", "SPEAKER_1=Anna")

        result = _invoke(str(markdown_folder), "--revert")

        assert result.exit_code == 0, result.output
        assert "Restored transcript.md, summary.md" in result.output

    def test_needs_a_map_or_revert(self, markdown_folder):
        result = _invoke(str(markdown_folder))

        assert result.exit_code == 2
        assert "--map" in result.output

    def test_revert_and_map_do_not_mix(self, markdown_folder):
        result = _invoke(str(markdown_folder), "--revert", "--map", "SPEAKER_1=Anna")

        assert result.exit_code == 2

    def test_a_busy_folder_exits_75(self, markdown_folder, hold_folder_lock):
        with hold_folder_lock(markdown_folder) as holder:
            result = _invoke(str(markdown_folder), "--map", "SPEAKER_1=Anna")

        assert result.exit_code == 75
        assert str(holder.pid) in result.output


def _runs() -> TranscriptResult:
    """A speaks three lines in a row, then B one."""
    return TranscriptResult(
        segments=[
            Segment(text="One.", start=0.0, end=1.0, speaker="A"),
            Segment(text="Two.", start=1.0, end=2.0, speaker="A"),
            Segment(text="Three.", start=2.0, end=3.0, speaker="A"),
            Segment(text="Four.", start=3.0, end=4.0, speaker="B"),
        ],
        language="en",
        duration=4.0,
    )


@pytest.fixture
def runs_folder(tmp_path):
    folder = tmp_path / "260103-planning"
    folder.mkdir()
    (folder / "transcript.md").write_text(format_transcript(_runs()))
    (folder / "summary.md").write_text(format_summary("A planned, B agreed."))
    return folder


def _speakers(folder) -> list[str | None]:
    transcript = read_transcript(folder)
    assert transcript is not None and transcript.result is not None
    return [seg.speaker for seg in transcript.result.segments]


def _turn_speakers(folder) -> list[str | None]:
    transcript = read_transcript(folder)
    assert transcript is not None and transcript.result is not None
    return [turn.speaker for turn in build_turns(transcript.result)]


def _revision(folder) -> str:
    transcript = read_transcript(folder)
    assert transcript is not None
    return transcript.revision


class TestMoves:
    def test_moving_a_middle_line_splits_its_turn(self, runs_folder):
        edit_speakers(runs_folder, moves={1: "B"}, revision=_revision(runs_folder))

        assert _speakers(runs_folder) == ["A", "B", "A", "B"]
        assert _turn_speakers(runs_folder) == ["A", "B", "A", "B"]

    def test_moving_a_whole_turn_joins_its_neighbours(self, runs_folder):
        edit_speakers(runs_folder, moves={3: "A"}, revision=_revision(runs_folder))

        assert _turn_speakers(runs_folder) == ["A"]
        assert (runs_folder / "transcript.md").read_text() == format_transcript(
            TranscriptResult(
                segments=[Segment(text=t, start=s, end=0.0, speaker="A") for t, s in _lines(_runs())],
                language="en",
                duration=4.0,
            )
        )

    def test_a_line_can_go_to_a_new_speaker(self, runs_folder):
        edit_speakers(runs_folder, moves={0: "Carla"}, revision=_revision(runs_folder))

        assert _speakers(runs_folder) == ["Carla", "A", "A", "B"]

    def test_moves_come_before_renames(self, runs_folder):
        edit_speakers(runs_folder, moves={0: "B"}, renames={"B": "Ben"}, revision=_revision(runs_folder))

        assert _speakers(runs_folder) == ["Ben", "A", "A", "Ben"]
        assert (runs_folder / "summary.md").read_text() == format_summary("A planned, Ben agreed.")

    def test_moving_a_line_to_its_own_speaker_changes_nothing(self, runs_folder):
        assert edit_speakers(runs_folder, moves={0: "A"}, revision=_revision(runs_folder)) == []
        assert not list(runs_folder.glob("*.orig"))

    def test_a_changed_transcript_is_refused_with_exit_65(self, runs_folder):
        before = (runs_folder / "transcript.md").read_bytes()

        with pytest.raises(TranscriptChangedError) as refused:
            edit_speakers(runs_folder, moves={1: "B"}, revision="0" * 64)

        assert refused.value.exit_code == 65
        assert (runs_folder / "transcript.md").read_bytes() == before

    def test_moving_lines_needs_a_revision(self, runs_folder):
        with pytest.raises(click.UsageError, match="--revision"):
            edit_speakers(runs_folder, moves={1: "B"})

    def test_a_line_that_does_not_exist_is_refused(self, runs_folder):
        with pytest.raises(click.ClickException, match="no line 9"):
            edit_speakers(runs_folder, moves={9: "B"}, revision=_revision(runs_folder))

    def test_both_transcript_formats_refuse_moves(self, runs_folder):
        (runs_folder / "transcript.json").write_text(format_transcript_json(_runs()))

        with pytest.raises(click.ClickException, match="single transcript"):
            edit_speakers(runs_folder, moves={1: "B"}, revision=_revision(runs_folder))

    def test_json_moves_the_segment_and_its_words(self, json_folder):
        edit_speakers(json_folder, moves={0: "Carla"}, revision=_revision(json_folder))

        transcript = json.loads((json_folder / "transcript.json").read_text())
        assert transcript["segments"][0]["speaker"] == "Carla"
        assert transcript["segments"][0]["words"][0]["speaker"] == "Carla"
        assert transcript["segments"][1]["speaker"] == "SPEAKER_10"


class TestStaleSummary:
    def test_a_move_marks_the_summary_stale_and_leaves_it_as_it_was(self, runs_folder):
        summary = (runs_folder / "summary.md").read_bytes()

        edit_speakers(runs_folder, moves={1: "B"}, revision=_revision(runs_folder))

        assert summary_is_stale(runs_folder)
        assert (runs_folder / "summary.md").read_bytes() == summary

    def test_a_rename_keeps_the_summary_current(self, runs_folder):
        edit_speakers(runs_folder, renames={"A": "Anna"})

        assert not summary_is_stale(runs_folder)

    def test_without_a_summary_there_is_nothing_to_mark(self, runs_folder):
        (runs_folder / "summary.md").unlink()

        edit_speakers(runs_folder, moves={1: "B"}, revision=_revision(runs_folder))

        assert not (runs_folder / ".ownscribe.json").exists()

    def test_revert_restores_an_older_layout_and_clears_the_mark(self, runs_folder):
        # Two headers in a row for one speaker: the layout a rename-speakers merge leaves.
        older = format_transcript(_runs()).replace("**B** [00:03]", "**A** [00:03]")
        (runs_folder / "transcript.md").write_text(older)

        edit_speakers(runs_folder, moves={0: "B"}, revision=_revision(runs_folder))
        assert (runs_folder / "transcript.md.orig").read_text() == older
        revert_speaker_edits(runs_folder)

        assert (runs_folder / "transcript.md").read_text() == older
        assert not summary_is_stale(runs_folder)


class TestAssignOption:
    def test_moves_a_line(self, runs_folder):
        result = _invoke(str(runs_folder), "--assign", "1=B", "--revision", _revision(runs_folder))

        assert result.exit_code == 0, result.output
        assert _speakers(runs_folder) == ["A", "B", "A", "B"]

    @pytest.mark.parametrize("assign", ["x=B", "-1=B", "1=", "1"])
    def test_a_malformed_assignment_is_a_usage_error(self, runs_folder, assign):
        result = _invoke(str(runs_folder), "--assign", assign, "--revision", _revision(runs_folder))

        assert result.exit_code == 2
        assert "INDEX=Name" in result.output

    def test_a_line_assigned_twice_is_a_usage_error(self, runs_folder):
        result = _invoke(str(runs_folder), "--assign", "1=B", "--assign", "1=A", "--revision", _revision(runs_folder))

        assert result.exit_code == 2
        assert "twice" in result.output

    def test_a_stale_revision_exits_65(self, runs_folder):
        result = _invoke(str(runs_folder), "--assign", "1=B", "--revision", "0" * 64)

        assert result.exit_code == 65
        assert "changed since it was read" in result.output


def _lines(result: TranscriptResult) -> list[tuple[str, float]]:
    return [(seg.text, seg.start) for seg in result.segments]
