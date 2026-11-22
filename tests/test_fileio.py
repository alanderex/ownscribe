"""Tests for atomic file replacement."""

from __future__ import annotations

from unittest import mock

import pytest

from ownscribe.fileio import write_atomic


class TestWriteAtomic:
    def test_creates_a_file(self, tmp_path):
        target = tmp_path / "summary.md"

        write_atomic(target, "# Meeting Summary\n\nÜbersicht.\n")

        assert target.read_text(encoding="utf-8") == "# Meeting Summary\n\nÜbersicht.\n"

    def test_writes_text_without_translating_newlines(self, tmp_path):
        target = tmp_path / "transcript.md"

        write_atomic(target, "a\r\nb\n")

        assert target.read_bytes() == b"a\r\nb\n"

    def test_writes_bytes_exactly(self, tmp_path):
        target = tmp_path / "transcript.md.orig"

        write_atomic(target, b"\xef\xbb\xbfraw\r\n")

        assert target.read_bytes() == b"\xef\xbb\xbfraw\r\n"

    def test_replacing_keeps_the_permissions(self, tmp_path):
        target = tmp_path / "transcript.md"
        target.write_text("old")
        target.chmod(0o640)

        write_atomic(target, "new")

        assert target.read_text() == "new"
        assert target.stat().st_mode & 0o777 == 0o640

    def test_a_failed_replace_leaves_the_old_file_and_no_temporary_file(self, tmp_path):
        target = tmp_path / "transcript.md"
        target.write_text("old")

        with mock.patch("ownscribe.fileio.os.replace", side_effect=OSError("disk full")), pytest.raises(OSError):
            write_atomic(target, "new")

        assert target.read_text() == "old"
        assert [p.name for p in tmp_path.iterdir()] == ["transcript.md"]
