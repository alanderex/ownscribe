"""Fallback recorder using sounddevice (mic or virtual device)."""

from __future__ import annotations

import queue
import threading
import time as _time
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

from ownscribe.audio.base import AudioRecorder

# RMS below this counts as silence for auto-stop. ~-40 dBFS, matching
# kMicLoudThreshold in the Swift helper — both are judging a microphone.
#
# This was 1e-4 (~-80 dBFS), which no real room ever reaches: a quiet room
# measured on an 8-minute test recording sat at RMS ~2.3e-3, twenty-three times
# above it, so silence auto-stop could never fire on this backend either. The
# Swift helper had the same bug via its measure (peak instead of RMS); this one
# had it via the threshold.
_SILENCE_THRESHOLD = 1e-2


class SoundDeviceRecorder(AudioRecorder):
    """Records from any audio input device using sounddevice + soundfile."""

    def __init__(
        self,
        device: str | int | None = None,
        samplerate: int = 48000,
        channels: int = 1,
        silence_timeout: int = 0,
    ) -> None:
        self._device = device
        self._samplerate = samplerate
        self._channels = channels
        self._silence_timeout = silence_timeout
        self._stream: sd.InputStream | None = None
        self._file: sf.SoundFile | None = None
        self._lock = threading.Lock()
        self._last_loud_time: float = 0.0
        self._timed_out: bool = False
        self._queue: queue.Queue = queue.Queue()
        self._writer: threading.Thread | None = None
        self._writer_done = threading.Event()

    def is_available(self) -> bool:
        try:
            sd.query_devices()
            return True
        except Exception:
            return False

    def start(self, output_path: Path) -> None:
        self._last_loud_time = _time.monotonic()
        self._timed_out = False

        self._file = sf.SoundFile(
            str(output_path),
            mode="w",
            samplerate=self._samplerate,
            channels=self._channels,
            format="WAV",
            subtype="FLOAT",
        )

        self._queue = queue.Queue()
        self._writer_done = threading.Event()
        self._writer = threading.Thread(target=self._write_loop, daemon=True)
        self._writer.start()

        def callback(indata, frames, time, status):
            # PortAudio calls this on a real-time thread. Writing to disk here — an
            # allocation, a lock and a blocking write — glitches or drops audio when
            # the disk stalls, so the buffer is only handed to a writer thread.
            self._queue.put(indata.copy())

            # Silence tracking. RMS, not peak, for the same reason as the Swift
            # helper: a single transient would otherwise keep resetting the timer,
            # so auto-stop never fired in a room with any noise floor at all.
            if self._silence_timeout > 0:
                level = float(np.sqrt(np.mean(np.square(indata, dtype=np.float64))))
                if level > _SILENCE_THRESHOLD:
                    self._last_loud_time = _time.monotonic()
                elif _time.monotonic() - self._last_loud_time > self._silence_timeout:
                    self._timed_out = True
                    raise sd.CallbackStop

        self._stream = sd.InputStream(
            device=self._device,
            samplerate=self._samplerate,
            channels=self._channels,
            callback=callback,
        )
        self._stream.start()

    def _write_loop(self) -> None:
        """Drain captured buffers to disk off the audio thread."""
        while True:
            chunk = self._queue.get()
            if chunk is None:  # sentinel from stop()
                self._writer_done.set()
                return
            with self._lock:
                if self._file is not None:
                    self._file.write(chunk)

    @property
    def is_recording(self) -> bool:
        return not self._timed_out and self._stream is not None and getattr(self._stream, "active", False)

    @property
    def silence_timed_out(self) -> bool:
        return self._timed_out

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        # Drain before closing: buffers still queued would otherwise be dropped,
        # truncating the end of every recording.
        if self._writer is not None:
            self._queue.put(None)
            self._writer_done.wait(timeout=30)
            self._writer = None
        with self._lock:
            if self._file is not None:
                self._file.close()
                self._file = None

    @staticmethod
    def list_devices() -> str:
        return str(sd.query_devices())
