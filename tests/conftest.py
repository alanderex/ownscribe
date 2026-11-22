"""Shared fixtures for ownscribe tests."""

from __future__ import annotations

import math
import os
import struct
import subprocess
import sys
import tempfile
import wave
from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager, contextmanager
from pathlib import Path

import pytest

from ownscribe.transcription.models import Segment, TranscriptResult


@pytest.fixture
def sample_transcript() -> TranscriptResult:
    """A basic transcript with two segments, no speakers."""
    return TranscriptResult(
        segments=[
            Segment(text="Hello world.", start=0.0, end=1.5),
            Segment(text="How are you?", start=1.5, end=3.0),
        ],
        language="en",
        duration=3.0,
    )


@pytest.fixture
def diarized_transcript() -> TranscriptResult:
    """A transcript with speaker labels."""
    return TranscriptResult(
        segments=[
            Segment(text="Hi, let's get started.", start=0.0, end=2.0, speaker="SPEAKER_00"),
            Segment(text="Sounds good.", start=2.0, end=3.5, speaker="SPEAKER_01"),
            Segment(text="First topic is the budget.", start=3.5, end=6.0, speaker="SPEAKER_00"),
        ],
        language="en",
        duration=6.0,
    )


@pytest.fixture
def tmp_config_file(tmp_path):
    """Write a minimal TOML config to a temp directory and return its path."""
    config_toml = tmp_path / "config.toml"
    config_toml.write_text('[transcription]\nmodel = "large-v3"\n\n[output]\ndir = "/tmp/test-notes"\n')
    return config_toml


@pytest.fixture
def synthetic_wav() -> Path:
    """Generate a 0.5s 440Hz sine wave WAV file (16-bit PCM, 16kHz mono)."""
    sample_rate = 16000
    duration = 0.5
    frequency = 440.0
    n_samples = int(sample_rate * duration)

    samples = []
    for i in range(n_samples):
        t = i / sample_rate
        value = int(32767 * 0.5 * math.sin(2 * math.pi * frequency * t))
        samples.append(struct.pack("<h", value))

    raw = b"".join(samples)

    fd, path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)

    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(raw)

    yield Path(path)

    Path(path).unlink(missing_ok=True)


# Folder locks are per process, so only another process can show that one excludes
# the other; threads in this process would share the lock.
_HOLD_LOCK = """
import sys
from pathlib import Path
from ownscribe.locks import folder_lock
with folder_lock(Path(sys.argv[1]), "test"):
    print("locked", flush=True)
    sys.stdin.read()
"""

_TRY_LOCK = """
import sys
from pathlib import Path
from ownscribe.locks import FolderBusyError, folder_lock
try:
    with folder_lock(Path(sys.argv[1]), "test"):
        print("took")
except FolderBusyError as exc:
    print("busy", exc.holder_pid)
"""


@pytest.fixture
def hold_folder_lock() -> Callable[[Path], AbstractContextManager[subprocess.Popen[str]]]:
    """Hold a folder's lock from another process for the duration of a block."""

    @contextmanager
    def hold(folder: Path) -> Iterator[subprocess.Popen[str]]:
        proc = subprocess.Popen(
            [sys.executable, "-c", _HOLD_LOCK, str(folder)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert proc.stdin is not None and proc.stdout is not None
        try:
            assert proc.stdout.readline().strip() == "locked"
            yield proc
        finally:
            proc.stdin.close()
            proc.wait(timeout=10)

    return hold


@pytest.fixture
def other_process_lock() -> Callable[[Path], str]:
    """Try to take a folder's lock from another process: "took" or "busy <pid>"."""

    def attempt(folder: Path) -> str:
        done = subprocess.run(
            [sys.executable, "-c", _TRY_LOCK, str(folder)], capture_output=True, text=True, timeout=30, check=True
        )
        return done.stdout.strip()

    return attempt


def _running_in_ci() -> bool:
    return os.environ.get("CI", "").lower() in ("true", "1", "yes")


@pytest.fixture
def in_ci() -> bool:
    """True on a CI runner, a shared virtual machine slower than a developer's Mac."""
    return _running_in_ci()


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """Auto-skip tests based on platform and environment."""
    in_ci = _running_in_ci()

    for item in items:
        if "hardware" in item.keywords and in_ci:
            item.add_marker(pytest.mark.skip(reason="hardware tests disabled in CI"))
        if "macos" in item.keywords and sys.platform != "darwin":
            item.add_marker(pytest.mark.skip(reason="macOS-only test"))
