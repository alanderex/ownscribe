"""Tests for meeting tags: `ownscribe tag` and `ownscribe tags`."""

from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

import click
import pytest
from click.testing import CliRunner

from ownscribe.cli import cli
from ownscribe.config import Config
from ownscribe.locks import FolderBusyError, LockState
from ownscribe.meeting_meta import META_NAME, mark_summary_stale, read_meta, summary_is_stale
from ownscribe.tags import TagBusyError, check_tag, delete_tag, edit_tags, group_tags, library_tags, meeting_tags


@pytest.fixture
def library(tmp_path) -> Config:
    """An output directory with three meetings and no tags."""
    for name in ("260101-kickoff", "260102-sync", "260103-review"):
        (tmp_path / name).mkdir()
        (tmp_path / name / "transcript.md").write_text("# Transcript\n\n[00:00] Hello.\n")
    config = Config()
    config.output.dir = str(tmp_path)
    return config


def _folder(config: Config, name: str) -> Path:
    return config.output.resolved_dir / name


def _tag(config: Config, *args: str):
    return _invoke(config, "tag", *args)


def _invoke(config: Config, *args: str):
    with mock.patch("ownscribe.cli.Config.load", return_value=config):
        return CliRunner().invoke(cli, list(args))


def _write_tags(folder: Path, tags: list[str]) -> None:
    """Tags as a hand edit or an older run might have left them."""
    (folder / META_NAME).write_text(json.dumps({"schema": 1, "tags": tags}))


class TestCheckTag:
    def test_a_tag_is_trimmed(self):
        assert check_tag("  ClientX ") == "ClientX"

    @pytest.mark.parametrize("text", ["", "   ", "Client\nX", "Client\rX"])
    def test_empty_and_multi_line_tags_are_refused(self, text):
        with pytest.raises(click.BadParameter):
            check_tag(text)


class TestGroupTags:
    def test_case_variants_are_one_tag_in_the_first_spelling(self):
        grouped = group_tags([(Path("a"), ["ClientX"]), (Path("b"), ["clientx", "Q4"]), (Path("c"), ["CLIENTX"])])
        assert grouped["clientx"].name == "ClientX"
        assert grouped["clientx"].folders == (Path("a"), Path("b"), Path("c"))
        assert grouped["q4"].count == 1

    def test_a_folder_counts_once_per_tag(self):
        # A hand-edited file may hold two spellings of one tag.
        assert group_tags([(Path("a"), ["ClientX", "clientx"])])["clientx"].count == 1


class TestEditTags:
    def test_adds_tags_in_order(self, library):
        folder = _folder(library, "260101-kickoff")
        assert edit_tags(library, folder, add=["ClientX", "Q4"], remove=[]) == ["ClientX", "Q4"]
        assert read_meta(folder)["tags"] == ["ClientX", "Q4"]

    def test_a_new_tag_takes_the_library_spelling(self, library):
        edit_tags(library, _folder(library, "260101-kickoff"), add=["ClientX"], remove=[])
        assert edit_tags(library, _folder(library, "260103-review"), add=["clientx"], remove=[]) == ["ClientX"]

    def test_adding_a_tag_the_meeting_has_changes_nothing(self, library):
        folder = _folder(library, "260101-kickoff")
        edit_tags(library, folder, add=["ClientX"], remove=[])
        before = (folder / META_NAME).stat().st_mtime_ns
        assert edit_tags(library, folder, add=["CLIENTX"], remove=[]) == ["ClientX"]
        assert (folder / META_NAME).stat().st_mtime_ns == before

    def test_removes_whatever_the_spelling(self, library):
        folder = _folder(library, "260101-kickoff")
        edit_tags(library, folder, add=["ClientX", "Q4"], remove=[])
        assert edit_tags(library, folder, add=[], remove=["clientx"]) == ["Q4"]

    def test_removing_the_last_tag_drops_the_key(self, library):
        folder = _folder(library, "260101-kickoff")
        edit_tags(library, folder, add=["ClientX"], remove=[])
        edit_tags(library, folder, add=[], remove=["ClientX"])
        assert "tags" not in read_meta(folder)

    def test_removing_a_tag_the_meeting_lacks_is_refused(self, library):
        folder = _folder(library, "260101-kickoff")
        edit_tags(library, folder, add=["Q4"], remove=[])
        with pytest.raises(click.ClickException, match=r"has no tag ClientX \(it has Q4\)"):
            edit_tags(library, folder, add=[], remove=["ClientX"])
        assert meeting_tags(folder) == ["Q4"]

    def test_adding_and_removing_one_tag_is_refused(self, library):
        with pytest.raises(click.UsageError, match="same tag"):
            edit_tags(library, _folder(library, "260101-kickoff"), add=["Q4"], remove=["q4"])

    def test_other_metadata_is_kept(self, library):
        folder = _folder(library, "260101-kickoff")
        mark_summary_stale(folder)
        edit_tags(library, folder, add=["ClientX"], remove=[])
        assert summary_is_stale(folder)

    def test_a_folder_another_process_holds_is_refused(self, library, hold_folder_lock):
        folder = _folder(library, "260101-kickoff")
        with hold_folder_lock(folder), pytest.raises(FolderBusyError):
            edit_tags(library, folder, add=["ClientX"], remove=[])
        assert not (folder / META_NAME).exists()

    def test_tags_that_are_not_a_list_of_text_are_reported(self, library):
        folder = _folder(library, "260101-kickoff")
        (folder / META_NAME).write_text(json.dumps({"schema": 1, "tags": "ClientX"}))
        with pytest.raises(click.ClickException, match="tags must be a list of text"):
            edit_tags(library, folder, add=["Q4"], remove=[])


class TestLibraryTags:
    def test_counts_meetings_per_tag(self, library):
        edit_tags(library, _folder(library, "260101-kickoff"), add=["ClientX", "Q4"], remove=[])
        edit_tags(library, _folder(library, "260102-sync"), add=["ClientX"], remove=[])
        tags = library_tags(library)
        assert {key: (tag.name, tag.count) for key, tag in tags.items()} == {"clientx": ("ClientX", 2), "q4": ("Q4", 1)}

    def test_a_missing_output_directory_has_no_tags(self, tmp_path):
        config = Config()
        config.output.dir = str(tmp_path / "nothing-recorded-yet")
        assert library_tags(config) == {}


class TestTagCommand:
    def test_prints_the_meeting_tags(self, library):
        folder = _folder(library, "260101-kickoff")
        result = _tag(library, str(folder), "--add", "ClientX", "--add", "Q4")
        assert result.exit_code == 0, result.output
        assert result.output == "Tags of 260101-kickoff: ClientX, Q4\n"

    def test_nothing_to_do_is_a_usage_error(self, library):
        result = _tag(library, str(_folder(library, "260101-kickoff")))
        assert result.exit_code == 2
        assert "--add TAG or --remove TAG" in result.output

    def test_a_busy_folder_exits_75(self, library, hold_folder_lock):
        folder = _folder(library, "260101-kickoff")
        with hold_folder_lock(folder):
            result = _tag(library, str(folder), "--add", "ClientX")
        assert result.exit_code == 75


class TestTagsListing:
    def test_lists_every_tag_with_its_count_by_name(self, library):
        edit_tags(library, _folder(library, "260101-kickoff"), add=["q4", "ClientX"], remove=[])
        edit_tags(library, _folder(library, "260102-sync"), add=["clientx"], remove=[])
        result = _invoke(library, "tags", "--json")
        assert result.exit_code == 0, result.output
        assert json.loads(result.output) == {
            "schema": 1,
            "tags": [{"name": "ClientX", "count": 2}, {"name": "q4", "count": 1}],
        }

    def test_needs_json_or_delete_and_not_both(self, library):
        assert _invoke(library, "tags").exit_code == 2
        assert _invoke(library, "tags", "--json", "--delete", "Q4").exit_code == 2


class TestDeleteTag:
    def test_removes_the_tag_from_every_meeting_in_any_spelling(self, library):
        _write_tags(_folder(library, "260101-kickoff"), ["ClientX", "Q4"])
        _write_tags(_folder(library, "260102-sync"), ["clientx"])
        result = _invoke(library, "tags", "--delete", "CLIENTX")
        assert result.exit_code == 0, result.output
        assert result.output == "Removed 'ClientX' from 2 meetings.\n"
        assert meeting_tags(_folder(library, "260101-kickoff")) == ["Q4"]
        assert "tags" not in read_meta(_folder(library, "260102-sync"))

    def test_a_tag_no_meeting_has_is_an_error(self, library):
        result = _invoke(library, "tags", "--delete", "Nope")
        assert result.exit_code == 1
        assert "No meeting has the tag 'Nope'" in result.output

    def test_a_busy_meeting_with_the_tag_stops_it_before_any_change(self, library, hold_folder_lock):
        for name in ("260101-kickoff", "260102-sync", "260103-review"):
            _write_tags(_folder(library, name), ["ClientX"])
        untouched = ("260101-kickoff", "260103-review")
        before = {name: (_folder(library, name) / META_NAME).read_bytes() for name in untouched}
        with hold_folder_lock(_folder(library, "260102-sync")):
            result = _invoke(library, "tags", "--delete", "ClientX")
        assert result.exit_code == 75
        assert "Nothing changed: 1 meeting with 'ClientX' is busy now" in result.output
        assert str(_folder(library, "260102-sync")) in result.output
        assert {name: (_folder(library, name) / META_NAME).read_bytes() for name in before} == before

    def test_a_meeting_that_becomes_busy_stops_it_and_is_named(self, library, hold_folder_lock):
        for name in ("260101-kickoff", "260102-sync", "260103-review"):
            _write_tags(_folder(library, name), ["ClientX"])
        # The folder is taken between the check and its turn.
        with (
            hold_folder_lock(_folder(library, "260102-sync")),
            mock.patch("ownscribe.tags.probe", return_value=LockState(busy=False)),
            pytest.raises(TagBusyError) as stopped,
        ):
            delete_tag(library, "ClientX")
        message = stopped.value.message
        assert message.startswith("Removed 'ClientX' from 1 meeting; these became busy and still have it:")
        assert str(_folder(library, "260102-sync")) in message
        assert str(_folder(library, "260103-review")) in message
        assert meeting_tags(_folder(library, "260101-kickoff")) == []
        assert meeting_tags(_folder(library, "260103-review")) == ["ClientX"]
