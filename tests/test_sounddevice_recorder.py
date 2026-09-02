"""Tests for the sounddevice fallback recorder.

This recorder had no tests at all, despite being the only capture path on Intel
Macs and non-macOS — and despite its callback being rewritten (buffers are now
queued to a writer thread, and silence is measured by RMS rather than peak).

`sounddevice` needs PortAudio, which is not present on a Linux runner and is
awkward in CI, so it is stubbed. That also makes these tests deterministic:
a real InputStream would deliver buffers on its own schedule.
"""

from __future__ import annotations

import sys
import threading
import types

import numpy as np
import pytest


class _FakeStream:
    """Stands in for sd.InputStream; the test drives the callback by hand."""

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.active = False
        self.callback = kwargs.get("callback")

    def start(self):
        self.active = True

    def stop(self):
        self.active = False

    def close(self):
        self.active = False


@pytest.fixture
def sd_stub(monkeypatch):
    stub = types.ModuleType("sounddevice")

    class CallbackStop(Exception):
        pass

    stub.CallbackStop = CallbackStop
    stub.InputStream = _FakeStream
    stub.query_devices = lambda: "fake device list"
    monkeypatch.setitem(sys.modules, "sounddevice", stub)
    # Drop any previously imported copy so the module binds to the stub.
    monkeypatch.delitem(sys.modules, "ownscribe.audio.sounddevice_recorder", raising=False)
    return stub


@pytest.fixture
def recorder_cls(sd_stub):
    from ownscribe.audio.sounddevice_recorder import SoundDeviceRecorder

    return SoundDeviceRecorder


def _buffer(level: float, frames: int = 512) -> np.ndarray:
    """A constant-level mono buffer; RMS == level."""
    return np.full((frames, 1), level, dtype=np.float32)


def _transient(peak: float, frames: int = 4096) -> np.ndarray:
    """Silence with a single loud sample — high peak, negligible RMS.

    4096 frames is the tap size the Swift helper uses; the ratio between peak and
    RMS is exactly what distinguishes a keystroke from speech.
    """
    buf = np.zeros((frames, 1), dtype=np.float32)
    buf[0, 0] = peak
    return buf


class TestCapture:
    def test_buffers_reach_the_file(self, recorder_cls, tmp_path):
        import soundfile as sf

        path = tmp_path / "recording.wav"
        rec = recorder_cls(samplerate=8000, channels=1)
        rec.start(path)
        for _ in range(4):
            rec._stream.callback(_buffer(0.5), 512, None, None)
        rec.stop()

        data, samplerate = sf.read(path)
        assert samplerate == 8000
        assert len(data) == 4 * 512
        assert np.allclose(data, 0.5, atol=1e-3)

    def test_stop_drains_queued_buffers(self, recorder_cls, tmp_path):
        """Closing the file before the queue drained truncated every recording."""
        import soundfile as sf

        path = tmp_path / "recording.wav"
        rec = recorder_cls(samplerate=8000, channels=1)
        rec.start(path)
        # Pause the writer so everything is still queued when stop() is called.
        rec._lock.acquire()
        for _ in range(8):
            rec._stream.callback(_buffer(0.25), 512, None, None)
        rec._lock.release()
        rec.stop()

        assert len(sf.read(path)[0]) == 8 * 512

    def test_the_audio_callback_does_not_touch_the_disk(self, recorder_cls, tmp_path):
        """Blocking I/O on PortAudio's real-time thread glitches or drops audio."""
        path = tmp_path / "recording.wav"
        rec = recorder_cls(samplerate=8000, channels=1)
        rec.start(path)

        writing_threads: list[str] = []
        real_write = rec._file.write
        rec._file.write = lambda chunk: (  # type: ignore[method-assign]
            writing_threads.append(threading.current_thread().name),
            real_write(chunk),
        )[1]

        callback_thread = threading.current_thread().name
        rec._stream.callback(_buffer(0.3), 512, None, None)
        rec.stop()

        assert writing_threads, "buffer never reached the file"
        assert callback_thread not in writing_threads

    def test_device_and_rate_are_passed_through(self, recorder_cls, tmp_path):
        rec = recorder_cls(device=3, samplerate=16000, channels=2)
        rec.start(tmp_path / "recording.wav")
        kwargs = rec._stream.kwargs
        rec.stop()

        assert kwargs["device"] == 3
        assert kwargs["samplerate"] == 16000
        assert kwargs["channels"] == 2


class TestSilenceAutoStop:
    def test_disabled_by_default(self, recorder_cls, tmp_path):
        rec = recorder_cls(silence_timeout=0)
        rec.start(tmp_path / "recording.wav")
        # Far past any plausible timeout; with the feature off nothing should trip.
        rec._last_loud_time -= 10_000
        rec._stream.callback(_buffer(0.0), 512, None, None)
        rec.stop()

        assert rec.silence_timed_out is False

    def test_silence_past_the_timeout_stops_the_stream(self, recorder_cls, tmp_path, sd_stub):
        rec = recorder_cls(silence_timeout=60)
        rec.start(tmp_path / "recording.wav")
        rec._last_loud_time -= 61

        with pytest.raises(sd_stub.CallbackStop):
            rec._stream.callback(_buffer(0.0), 512, None, None)
        rec.stop()

        assert rec.silence_timed_out is True

    def test_sound_resets_the_timer(self, recorder_cls, tmp_path):
        rec = recorder_cls(silence_timeout=60)
        rec.start(tmp_path / "recording.wav")
        rec._last_loud_time -= 61

        rec._stream.callback(_buffer(0.5), 512, None, None)  # loud: resets
        rec._stream.callback(_buffer(0.0), 512, None, None)  # silence, but timer is fresh
        rec.stop()

        assert rec.silence_timed_out is False

    def test_a_single_transient_does_not_reset_the_timer(self, recorder_cls, tmp_path, sd_stub):
        """The peak-vs-RMS bug: one loud sample used to count as "sound".

        A keystroke in an otherwise silent room has a high peak and negligible
        RMS. Measured against peak, auto-stop never fired in a real room.
        """
        rec = recorder_cls(silence_timeout=60)
        rec.start(tmp_path / "recording.wav")
        rec._last_loud_time -= 61

        # Peak 0.5, fifty times the threshold — but RMS over the buffer is ~0.008.
        buf = _transient(0.5)
        assert float(np.abs(buf).max()) > 1e-2, "test buffer must have a loud peak"
        assert float(np.sqrt(np.mean(np.square(buf, dtype=np.float64)))) < 1e-2

        with pytest.raises(sd_stub.CallbackStop):
            rec._stream.callback(buf, len(buf), None, None)
        rec.stop()

        assert rec.silence_timed_out is True

    def test_room_tone_does_not_keep_the_recording_alive(self, recorder_cls, tmp_path, sd_stub):
        """The measured floor of a real quiet room was RMS ~2.3e-3.

        The threshold used to be 1e-4, twenty-three times below that, so ambient
        noise alone was enough to postpone auto-stop indefinitely.
        """
        rec = recorder_cls(silence_timeout=60)
        rec.start(tmp_path / "recording.wav")
        rec._last_loud_time -= 61

        with pytest.raises(sd_stub.CallbackStop):
            rec._stream.callback(_buffer(2.3e-3), 512, None, None)
        rec.stop()

        assert rec.silence_timed_out is True

    def test_speech_level_audio_still_counts_as_sound(self, recorder_cls, tmp_path):
        """The threshold must not be so high that quiet speech reads as silence."""
        rec = recorder_cls(silence_timeout=60)
        rec.start(tmp_path / "recording.wav")
        rec._last_loud_time -= 61

        rec._stream.callback(_buffer(0.05), 512, None, None)  # ~-26 dBFS, quiet speech
        rec.stop()

        assert rec.silence_timed_out is False

    def test_is_recording_reflects_the_timeout(self, recorder_cls, tmp_path, sd_stub):
        rec = recorder_cls(silence_timeout=60)
        rec.start(tmp_path / "recording.wav")

        assert rec.is_recording is True

        rec._last_loud_time -= 61
        with pytest.raises(sd_stub.CallbackStop):
            rec._stream.callback(_buffer(0.0), 512, None, None)

        assert rec.is_recording is False
        rec.stop()


class TestLifecycle:
    def test_stop_is_idempotent(self, recorder_cls, tmp_path):
        rec = recorder_cls()
        rec.start(tmp_path / "recording.wav")
        rec.stop()
        rec.stop()  # must not raise or hang

        assert rec.is_recording is False

    def test_is_available_reports_query_failure(self, recorder_cls, sd_stub):
        assert recorder_cls().is_available() is True

        def boom():
            raise OSError("no PortAudio")

        sd_stub.query_devices = boom
        assert recorder_cls().is_available() is False
