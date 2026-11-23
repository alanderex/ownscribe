"""Tests for a meeting's own title: `ownscribe title` and titles in `show`."""

from __future__ import annotations

import json
from unittest import mock

import click
import pytest
from click.testing import CliRunner

from ownscribe.cli import cli
from ownscribe.config import Config
from ownscribe.locks import FolderBusyError
from ownscribe.meeting_meta import META_NAME, mark_summary_stale, read_meta, summary_is_stale
from ownscribe.show import meeting_detail, meeting_rows
from ownscribe.tags import edit_tags
from ownscribe.titles import check_title, set_title


@pytest.fixture
def config(tmp_path) -> Config:
    config = Config()
    config.output.dir = str(tmp_path)
    return config


@pytest.fixture
def folder(config):
    folder = config.output.resolved_dir / "261119-KIBV-RGSW"
    folder.mkdir()
    (folder / "transcript.md").write_text("# Transcript\n\n[00:00] Hallo.\n")
    return folder


class TestCheckTitle:
    def test_a_title_is_trimmed(self):
        assert check_title("  KIBV RGSW ") == "KIBV RGSW"

    @pytest.mark.parametrize("text", ["", "  ", "KIBV\nRGSW", "KIBV\rRGSW"])
    def test_empty_and_multi_line_titles_are_refused(self, text):
        with pytest.raises(click.BadParameter):
            check_title(text)


class TestSetTitle:
    def test_show_uses_the_title_as_typed(self, config, folder):
        assert meeting_detail(config, folder)["title"] == "Kibv Rgsw"
        set_title(folder, "KIBV / RGSW: Kick-off")
        assert meeting_detail(config, folder)["title"] == "KIBV / RGSW: Kick-off"
        assert [row["title"] for row in meeting_rows(config)["meetings"]] == ["KIBV / RGSW: Kick-off"]

    def test_the_folder_keeps_its_name(self, config, folder):
        set_title(folder, "Kick-off")
        assert [p.name for p in config.output.resolved_dir.iterdir()] == ["261119-KIBV-RGSW"]

    def test_other_metadata_is_kept(self, config, folder):
        mark_summary_stale(folder)
        edit_tags(config, folder, add=["ClientX"], remove=[])
        set_title(folder, "Kick-off")
        assert summary_is_stale(folder)
        assert read_meta(folder)["tags"] == ["ClientX"]

    def test_a_folder_another_process_holds_is_refused(self, folder, hold_folder_lock):
        with hold_folder_lock(folder), pytest.raises(FolderBusyError):
            set_title(folder, "Kick-off")
        assert not (folder / META_NAME).exists()

    def test_a_title_that_is_not_text_is_reported(self, config, folder):
        (folder / META_NAME).write_text(json.dumps({"schema": 1, "title": ["Kick-off"]}))
        with pytest.raises(click.ClickException, match="title must be text"):
            meeting_detail(config, folder)


class TestTitleCommand:
    @staticmethod
    def _run(config: Config, *args: str):
        with mock.patch("ownscribe.cli.Config.load", return_value=config):
            return CliRunner().invoke(cli, ["title", *args])

    def test_prints_the_title(self, config, folder):
        result = self._run(config, str(folder), " KIBV RGSW ")
        assert result.exit_code == 0, result.output
        assert result.output == "Title of 261119-KIBV-RGSW: KIBV RGSW\n"

    def test_an_empty_title_is_a_usage_error(self, config, folder):
        assert self._run(config, str(folder), " ").exit_code == 2

    def test_a_busy_folder_exits_75(self, config, folder, hold_folder_lock):
        with hold_folder_lock(folder):
            assert self._run(config, str(folder), "Kick-off").exit_code == 75
