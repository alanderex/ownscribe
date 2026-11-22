"""Atomic file replacement for files other processes read while they change."""

from __future__ import annotations

import os
import stat
import tempfile
from pathlib import Path


def write_atomic(path: Path, data: str | bytes) -> None:
    """Replace `path` so a reader sees either the old contents or the new, never part.

    The data goes to a temporary file in the same directory, is flushed to disk,
    and then replaces `path` in one rename. An existing file's permissions carry
    over. Text is written as UTF-8 exactly as given (no newline translation).
    """
    payload = data.encode("utf-8") if isinstance(data, str) else data
    fd, temp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            temp.chmod(stat.S_IMODE(path.stat().st_mode))
        os.replace(temp, path)
    except BaseException:
        temp.unlink(missing_ok=True)
        raise
