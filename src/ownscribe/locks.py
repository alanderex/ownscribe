"""Per-folder locks for meeting folders.

One process works on a meeting folder at a time: a recording run from the moment
its folder is claimed, `resume`, and `edit-speakers` each hold
`<folder>/.ownscribe.lock`. `show` probes the lock to report busy folders and never
takes it.

These are POSIX record locks (fcntl), not flock: a probe asks with F_GETLK, which
reports a conflicting holder without acquiring anything, so probing can never make
a concurrent take fail.

A POSIX lock belongs to the process and is dropped when *any* descriptor of the
locked file is closed. So a process holds each lock through exactly one descriptor
and never opens the lock file again while holding it: the probe consults the
process's own holdings first, and nested use reuses the held lock.
"""

from __future__ import annotations

import errno
import fcntl
import json
import os
import struct
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import click

LOCK_NAME = ".ownscribe.lock"

#: EX_TEMPFAIL: the folder is busy now; a later attempt may succeed.
BUSY_EXIT_CODE = 75

# Darwin's struct flock: l_start, l_len (off_t), l_pid (pid_t), l_type, l_whence (short).
# ownscribe runs on macOS only; elsewhere the probe answers "unknown".
_DARWIN_FLOCK = "qqihh"

# The errors a non-blocking take reports when another process holds the lock.
_HELD_ERRNOS = (errno.EACCES, errno.EAGAIN)


class FolderBusyError(click.ClickException):
    """Another process holds the folder's lock; the command exits with 75."""

    exit_code = BUSY_EXIT_CODE

    def __init__(self, folder: Path, holder_pid: int | None) -> None:
        who = f"process {holder_pid}" if holder_pid else "another process"
        super().__init__(f"{folder} is busy: {who} is working on it. Try again once it has finished.")
        self.folder = folder
        self.holder_pid = holder_pid


@dataclass(frozen=True)
class LockState:
    """What a probe found: busy is True, False, or "unknown" where locks cannot be read."""

    busy: bool | Literal["unknown"]
    holder_pid: int | None = None


# Lock file (device, inode) -> the descriptor this process holds it through. Keyed by
# inode because a folder renamed while locked keeps its lock file and its lock.
_held: dict[tuple[int, int], int] = {}


@contextmanager
def folder_lock(folder: Path, kind: str) -> Iterator[None]:
    """Hold `folder`'s lock while the block runs.

    Raises FolderBusyError when another process holds it. Nested use in one process
    reuses the held lock. Any other failure to lock (a volume without lock support,
    a read-only folder) prints a warning and runs the block unlocked: refusing would
    leave meetings on such volumes impossible to process or edit.

    `kind` (record, resume, edit-speakers, ...) is written into the lock file for
    people reading it; nothing decides anything from its contents.
    """
    path = folder / LOCK_NAME
    if _file_key(path) in _held:
        yield
        return

    fd = _take(folder, path)
    if fd is None:
        yield
        return
    key = _fd_key(fd)
    _held[key] = fd
    try:
        _write_holder(fd, kind, folder)
        yield
    finally:
        del _held[key]
        os.close(fd)  # releases the lock


def probe(folder: Path) -> LockState:
    """Whether a process holds `folder`'s lock, without taking it."""
    path = folder / LOCK_NAME
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return LockState(busy=False)
    except OSError:
        return LockState(busy="unknown")
    if (st.st_dev, st.st_ino) in _held:
        # F_GETLK never reports the caller's own locks, and opening the file here
        # would drop the lock when the descriptor closes.
        return LockState(busy=True, holder_pid=os.getpid())
    if sys.platform != "darwin":
        return LockState(busy="unknown")
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return LockState(busy="unknown")
    try:
        pid = _conflicting_pid(fd)
    except OSError:
        return LockState(busy="unknown")
    finally:
        os.close(fd)
    return LockState(busy=pid is not None, holder_pid=pid)


def _take(folder: Path, path: Path) -> int | None:
    """Open and lock the lock file. None means: carry on unlocked (warned)."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as exc:
        _warn_unlocked(folder, exc)
        return None
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in _HELD_ERRNOS:
            holder = _conflicting_pid_or_none(fd)
            os.close(fd)
            raise FolderBusyError(folder, holder) from None
        os.close(fd)
        _warn_unlocked(folder, exc)
        return None
    return fd


def _write_holder(fd: int, kind: str, folder: Path) -> None:
    """Record who holds the lock, through the locking descriptor itself."""
    data = json.dumps({"pid": os.getpid(), "kind": kind, "folder": str(folder)}).encode()
    os.ftruncate(fd, 0)
    os.pwrite(fd, data, 0)


def _conflicting_pid(fd: int) -> int | None:
    """The pid of a process holding a lock that would block ours, or None."""
    request = struct.pack(_DARWIN_FLOCK, 0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET)
    reply = fcntl.fcntl(fd, fcntl.F_GETLK, request)
    _start, _length, pid, lock_type, _whence = struct.unpack(_DARWIN_FLOCK, reply)
    return None if lock_type == fcntl.F_UNLCK else pid


def _conflicting_pid_or_none(fd: int) -> int | None:
    """The holder's pid for the busy message; the message works without it."""
    if sys.platform != "darwin":
        return None
    try:
        return _conflicting_pid(fd)
    except OSError:
        return None


def _file_key(path: Path) -> tuple[int, int] | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    return st.st_dev, st.st_ino


def _fd_key(fd: int) -> tuple[int, int]:
    st = os.fstat(fd)
    return st.st_dev, st.st_ino


def _warn_unlocked(folder: Path, exc: OSError) -> None:
    click.echo(f"Warning: could not lock {folder} ({exc.strerror}); continuing without a lock.", err=True)
