"""Tests for per-folder locks: exclusion between processes, probing without taking."""

from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest

from ownscribe.locks import BUSY_EXIT_CODE, LOCK_NAME, FolderBusyError, LockState, folder_lock, probe

pytestmark = pytest.mark.macos

# Takes and releases the lock as fast as it can and counts the takes refused as busy.
_TAKE_REPEATEDLY = """
import sys
from pathlib import Path
from ownscribe.locks import FolderBusyError, folder_lock
refused = 0
for _ in range(int(sys.argv[2])):
    try:
        with folder_lock(Path(sys.argv[1]), "test"):
            pass
    except FolderBusyError:
        refused += 1
print(refused)
"""


@pytest.fixture
def folder(tmp_path):
    meeting = tmp_path / "260101-budget-review"
    meeting.mkdir()
    return meeting


class TestProbe:
    def test_a_never_locked_folder_is_free(self, folder):
        assert probe(folder) == LockState(busy=False)

    def test_a_lock_held_elsewhere_names_its_process(self, folder, hold_folder_lock):
        with hold_folder_lock(folder) as holder:
            assert probe(folder) == LockState(busy=True, holder_pid=holder.pid)

    def test_a_lock_is_free_again_once_its_holder_exits(self, folder, hold_folder_lock):
        with hold_folder_lock(folder):
            pass

        assert probe(folder) == LockState(busy=False)

    def test_probing_never_makes_a_take_fail(self, folder):
        """A probe that acquired, even briefly, would make a concurrent take report busy."""
        taker = subprocess.Popen(
            [sys.executable, "-c", _TAKE_REPEATEDLY, str(folder), "3000"], stdout=subprocess.PIPE, text=True
        )
        probes = 0
        while taker.poll() is None:
            probe(folder)
            probes += 1
        out, _ = taker.communicate(timeout=30)

        assert probes > 0
        assert int(out) == 0


class TestFolderLock:
    def test_a_lock_held_elsewhere_refuses_with_exit_75(self, folder, hold_folder_lock):
        with (
            hold_folder_lock(folder) as holder,
            pytest.raises(FolderBusyError) as raised,
            folder_lock(folder, "edit-speakers"),
        ):
            pytest.fail("took a lock another process holds")

        assert raised.value.exit_code == BUSY_EXIT_CODE == 75
        assert raised.value.holder_pid == holder.pid
        assert str(holder.pid) in raised.value.format_message()

    def test_holding_it_excludes_other_processes(self, folder, other_process_lock):
        with folder_lock(folder, "resume"):
            assert other_process_lock(folder) == f"busy {os.getpid()}"

        assert other_process_lock(folder) == "took"

    def test_the_holder_is_written_into_the_lock_file(self, folder):
        with folder_lock(folder, "resume"):
            holder = json.loads((folder / LOCK_NAME).read_text())

        assert holder == {"pid": os.getpid(), "kind": "resume", "folder": str(folder)}

    def test_probing_its_own_lock_keeps_it(self, folder, other_process_lock):
        """Opening and closing the lock file in the holding process would drop the lock."""
        with folder_lock(folder, "resume"):
            assert probe(folder) == LockState(busy=True, holder_pid=os.getpid())
            assert other_process_lock(folder) == f"busy {os.getpid()}"

    def test_nested_use_keeps_the_lock_until_the_outer_block_ends(self, folder, other_process_lock):
        with folder_lock(folder, "resume"):
            with folder_lock(folder, "summarize"):
                pass
            assert other_process_lock(folder) == f"busy {os.getpid()}"

        assert other_process_lock(folder) == "took"

    def test_renaming_a_locked_folder_keeps_the_lock(self, folder, other_process_lock):
        renamed = folder.with_name("260101-q2-budget-review")
        with folder_lock(folder, "record"):
            folder.rename(renamed)
            assert other_process_lock(renamed) == f"busy {os.getpid()}"
            assert probe(renamed) == LockState(busy=True, holder_pid=os.getpid())

    def test_an_unlockable_folder_runs_unlocked_with_a_warning(self, folder, capsys):
        folder.chmod(0o500)  # the lock file cannot be created
        try:
            ran = False
            with folder_lock(folder, "resume"):
                ran = True
        finally:
            folder.chmod(0o700)

        assert ran
        assert "could not lock" in capsys.readouterr().err
        assert not (folder / LOCK_NAME).exists()
