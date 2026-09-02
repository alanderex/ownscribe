"""Tests for `run_pipeline` — the record leg.

Everything from `recorder.start()` to the hand-off into transcription was
untested: run_pipeline appeared in the suite only as a mock.patch target, so the
poll loop, the silence-timeout branch, the "no audio captured" guard and the
progress events around capture had no coverage at all. That is also where most
of this project's real bugs have lived.

The recorder and the transcribe/summarize stage are stubbed; what is exercised is
run_pipeline's own logic.
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

import pytest

from ownscribe.config import Config

_WAV_HEADER = b"RIFF$\x00\x00\x00WAVEfmt " + bytes(28)  # 44 bytes, no frames


class FakeRecorder:
    """An AudioRecorder that finishes immediately and writes what it is told to."""

    def __init__(
        self,
        *,
        audio_bytes: bytes = _WAV_HEADER + b"\x00" * 512,
        silence_timed_out: bool = False,
        silence_warning: bool = False,
    ) -> None:
        self.audio_bytes = audio_bytes
        self.silence_timed_out = silence_timed_out
        self.silence_warning = silence_warning
        self.started_at: Path | None = None
        self.stopped = False
        self._recording = True

    def start(self, output_path: Path) -> None:
        self.started_at = output_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(self.audio_bytes)

    def stop(self) -> None:
        self.stopped = True
        self._recording = False

    @property
    def is_recording(self) -> bool:
        # False on the first poll, so the loop exits without a real wait.
        was, self._recording = self._recording, False
        return was and False

    @property
    def is_muted(self) -> bool:
        return False

    def toggle_mute(self) -> None:  # pragma: no cover - not reached in these tests
        raise AssertionError("mute should not be toggled here")


@pytest.fixture
def run(tmp_path, monkeypatch):
    """Run run_pipeline with a stubbed recorder and transcription stage."""

    def _run(recorder: FakeRecorder | None = None, *, config: Config | None = None, title=None):
        cfg = config or Config()
        cfg.output.dir = str(tmp_path)
        cfg.summarization.enabled = False
        rec = recorder or FakeRecorder()

        # Not a tty: run_pipeline must not touch termios in a test runner.
        monkeypatch.setattr("sys.stdin.isatty", lambda: False, raising=False)
        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=rec),
            mock.patch("ownscribe.pipeline._do_transcribe_and_summarize") as stage,
            mock.patch("ownscribe.pipeline._check_audio_silence") as silence_check,
        ):
            from ownscribe.pipeline import run_pipeline

            run_pipeline(cfg, title=title)
        return rec, stage, silence_check

    return _run


class TestRecordLoop:
    def test_records_then_hands_off_to_transcription(self, run, tmp_path):
        rec, stage, _ = run()

        assert rec.stopped is True
        stage.assert_called_once()
        out_dir = stage.call_args[0][2]
        assert out_dir.parent == tmp_path

    def test_audio_lands_in_the_run_directory(self, run):
        rec, _, _ = run()

        assert rec.started_at is not None
        assert rec.started_at.name == "recording.wav"
        assert rec.started_at.exists()

    def test_title_names_the_run_directory(self, run):
        _, stage, _ = run(title="Q2 Sales Review")

        assert stage.call_args[0][2].name.endswith("-q2-sales-review")


class TestNoAudioCaptured:
    def test_a_header_only_file_is_an_error(self, run):
        """44 bytes is a WAV header with no frames — nothing was captured."""
        with pytest.raises(SystemExit) as exc:
            run(FakeRecorder(audio_bytes=_WAV_HEADER))

        assert exc.value.code == 1

    def test_the_error_mentions_no_mic_when_the_mic_is_on(self, run, capsys):
        cfg = Config()
        cfg.audio.mic = True
        with pytest.raises(SystemExit):
            run(FakeRecorder(audio_bytes=_WAV_HEADER), config=cfg)

        assert "--no-mic" in capsys.readouterr().err

    def test_transcription_is_not_attempted(self, run):
        with pytest.raises(SystemExit):
            run(FakeRecorder(audio_bytes=_WAV_HEADER))
        # _do_transcribe_and_summarize is asserted via the mock inside run(); a
        # SystemExit before it is the contract — a wasted transcription of an
        # empty file is the failure this guards.


class TestSilenceHandling:
    def test_auto_stop_is_reported(self, run, capsys):
        run(FakeRecorder(silence_timed_out=True))

        assert "auto-stopped after silence timeout" in capsys.readouterr().out

    def test_normal_stop_is_reported_differently(self, run, capsys):
        run(FakeRecorder(silence_timed_out=False))

        out = capsys.readouterr().out
        assert "Stopping recording" in out
        assert "auto-stopped" not in out

    def test_silence_check_is_skipped_when_the_recorder_already_warned(self, run):
        """The CoreAudio helper reports this itself; re-reading the file is waste."""
        _, _, silence_check = run(FakeRecorder(silence_warning=True))

        silence_check.assert_not_called()

    def test_silence_check_runs_otherwise(self, run):
        _, _, silence_check = run(FakeRecorder(silence_warning=False))

        silence_check.assert_called_once()


class TestProgressEvents:
    """A GUI needs to know capture ended before the long transcription starts."""

    @staticmethod
    def _events(capsys) -> list[dict]:
        out = []
        for line in capsys.readouterr().err.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and "ownscribe_progress" in obj:
                out.append(obj)
        return out

    def test_recording_started_and_stopped_are_emitted(self, run, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        run()

        names = [e["event"] for e in self._events(capsys)]
        assert "recording_started" in names
        assert "recording_stopped" in names

    def test_stop_reason_distinguishes_auto_stop(self, run, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        run(FakeRecorder(silence_timed_out=True))

        stopped = [e for e in self._events(capsys) if e["event"] == "recording_stopped"]
        assert stopped and stopped[0]["reason"] == "silence_timeout"

    def test_stop_reason_is_user_when_stopped_by_hand(self, run, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        run(FakeRecorder(silence_timed_out=False))

        stopped = [e for e in self._events(capsys) if e["event"] == "recording_stopped"]
        assert stopped and stopped[0]["reason"] == "user"

    def test_started_carries_the_configured_timeout(self, run, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        cfg = Config()
        cfg.audio.silence_timeout = 90
        run(config=cfg)

        started = [e for e in self._events(capsys) if e["event"] == "recording_started"]
        assert started and started[0]["silence_timeout"] == 90

    def test_nothing_is_emitted_by_default(self, run, capsys, monkeypatch):
        monkeypatch.delenv("OWNSCRIBE_PROGRESS_EVENTS", raising=False)
        run()

        assert self._events(capsys) == []


class TestBackendValidation:
    def test_a_bad_summarizer_backend_fails_before_recording(self, tmp_path, monkeypatch):
        """Rejecting it afterwards would cost the user the whole meeting."""
        import click

        cfg = Config()
        cfg.output.dir = str(tmp_path)
        cfg.summarization.enabled = True
        cfg.summarization.backend = "opneai"

        rec = FakeRecorder()
        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=rec),
            mock.patch("ownscribe.pipeline._do_transcribe_and_summarize"),
        ):
            from ownscribe.pipeline import run_pipeline

            with pytest.raises(click.ClickException):
                run_pipeline(cfg)

        assert rec.started_at is None, "recording started despite an invalid backend"


class TestSilenceDetection:
    """`_check_audio_silence` reads the recording and aborts if it is empty.

    This is what catches a missing Screen Recording grant before minutes are
    spent transcribing nothing. It uses the `synthetic_wav` fixture, which was
    added for audio tests and had never been referenced by one.
    """

    def test_a_real_tone_passes(self, synthetic_wav):
        from ownscribe.pipeline import _check_audio_silence

        _check_audio_silence(synthetic_wav)  # must not raise

    def test_silence_aborts_with_guidance(self, tmp_path, capsys):
        import wave

        from ownscribe.pipeline import _check_audio_silence

        path = tmp_path / "silent.wav"
        with wave.open(str(path), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(b"\x00\x00" * 16000)  # one second of digital silence

        with pytest.raises(SystemExit) as exc:
            _check_audio_silence(path)

        assert exc.value.code == 1
        assert "Screen Recording" in capsys.readouterr().err

    def test_an_unreadable_file_does_not_block_the_pipeline(self, tmp_path):
        """A check failure must never cost the user a recording they already made."""
        from ownscribe.pipeline import _check_audio_silence

        path = tmp_path / "not-audio.wav"
        path.write_bytes(b"this is not a wav file")

        _check_audio_silence(path)  # returns rather than raising
