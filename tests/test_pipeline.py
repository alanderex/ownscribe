"""Tests for pipeline orchestration."""

from __future__ import annotations

import contextlib
import json
import logging
import os
import re
from unittest import mock

import pytest

from ownscribe.config import Config
from ownscribe.transcription.models import Segment, TranscriptResult


class TestCreateRecorder:
    def test_coreaudio_when_available(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "coreaudio"
        config.audio.device = ""

        with mock.patch("ownscribe.audio.coreaudio.CoreAudioRecorder") as mock_cls:
            mock_cls.return_value.is_available.return_value = True
            recorder = _create_recorder(config)
            assert recorder == mock_cls.return_value

    def test_fallback_to_sounddevice(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "coreaudio"
        config.audio.device = ""

        with (
            mock.patch("ownscribe.audio.coreaudio.CoreAudioRecorder") as mock_ca,
            mock.patch("ownscribe.audio.sounddevice_recorder.SoundDeviceRecorder") as mock_sd,
        ):
            mock_ca.return_value.is_available.return_value = False
            recorder = _create_recorder(config)
            assert recorder == mock_sd.return_value

    def test_sounddevice_when_device_set(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "coreaudio"
        config.audio.device = "USB Mic"

        with mock.patch("ownscribe.audio.sounddevice_recorder.SoundDeviceRecorder") as mock_sd:
            recorder = _create_recorder(config)
            assert recorder == mock_sd.return_value

    def test_silence_timeout_passed_to_coreaudio(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "coreaudio"
        config.audio.device = ""
        config.audio.silence_timeout = 120

        with mock.patch("ownscribe.audio.coreaudio.CoreAudioRecorder") as mock_cls:
            mock_cls.return_value.is_available.return_value = True
            _create_recorder(config)
            mock_cls.assert_called_once_with(mic=True, mic_device="", capture_mode="all", silence_timeout=120)

    def test_capture_mode_passed_to_coreaudio(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "coreaudio"
        config.audio.device = ""
        config.audio.capture_mode = "picker"

        with mock.patch("ownscribe.audio.coreaudio.CoreAudioRecorder") as mock_cls:
            mock_cls.return_value.is_available.return_value = True
            _create_recorder(config)
            mock_cls.assert_called_once_with(mic=True, mic_device="", capture_mode="picker", silence_timeout=300)

    def test_silence_timeout_passed_to_sounddevice(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "sounddevice"
        config.audio.device = "USB Mic"
        config.audio.silence_timeout = 60

        with mock.patch("ownscribe.audio.sounddevice_recorder.SoundDeviceRecorder") as mock_sd:
            _create_recorder(config)
            mock_sd.assert_called_once_with(device="USB Mic", silence_timeout=60)


class TestUnsupportedAudioSettings:
    """Flags the sounddevice backend cannot honour must warn, not be ignored."""

    @staticmethod
    def _create(config, capsys):
        from ownscribe.pipeline import _create_recorder

        with mock.patch("ownscribe.audio.sounddevice_recorder.SoundDeviceRecorder"):
            _create_recorder(config)
        return capsys.readouterr().err

    def test_mic_device_warns(self, capsys):
        config = Config()
        config.audio.backend = "sounddevice"
        config.audio.device = "USB Mic"
        config.audio.mic_device = "MacBook Pro Microphone"

        assert "--mic-device" in self._create(config, capsys)

    def test_no_mic_warns(self, capsys):
        config = Config()
        config.audio.backend = "sounddevice"
        config.audio.device = "USB Mic"
        config.audio.mic = False

        assert "--no-mic" in self._create(config, capsys)

    def test_capture_mode_warns(self, capsys):
        config = Config()
        config.audio.backend = "sounddevice"
        config.audio.device = "USB Mic"
        config.audio.capture_mode = "picker"

        assert "capture_mode" in self._create(config, capsys)

    def test_defaults_do_not_warn(self, capsys):
        config = Config()
        config.audio.backend = "sounddevice"
        config.audio.device = "USB Mic"

        assert self._create(config, capsys) == ""

    def test_coreaudio_backend_honours_the_flags(self):
        from ownscribe.pipeline import _create_recorder

        config = Config()
        config.audio.backend = "coreaudio"
        config.audio.device = ""
        config.audio.mic_device = "USB Mic"

        with mock.patch("ownscribe.audio.coreaudio.CoreAudioRecorder") as mock_cls:
            mock_cls.return_value.is_available.return_value = True
            _create_recorder(config)

        assert mock_cls.call_args.kwargs["mic_device"] == "USB Mic"


class TestFormatOutput:
    def test_markdown_format(self, sample_transcript):
        from ownscribe.pipeline import _format_output

        config = Config()
        config.output.format = "markdown"

        transcript_str, summary_str = _format_output(config, sample_transcript)
        assert "# Transcript" in transcript_str
        assert summary_str is None

    def test_markdown_with_summary(self, sample_transcript):
        from ownscribe.pipeline import _format_output

        config = Config()
        config.output.format = "markdown"

        transcript_str, summary_str = _format_output(config, sample_transcript, "A great meeting.")
        assert "# Transcript" in transcript_str
        assert "# Meeting Summary" in summary_str
        assert "A great meeting." in summary_str

    def test_json_format(self, sample_transcript):
        from ownscribe.pipeline import _format_output

        config = Config()
        config.output.format = "json"

        transcript_str, _summary_str = _format_output(config, sample_transcript)
        parsed = json.loads(transcript_str)
        assert "segments" in parsed

    def test_json_summary_is_json(self, sample_transcript):
        from ownscribe.pipeline import _format_output

        config = Config()
        config.output.format = "json"

        _transcript_str, summary_str = _format_output(config, sample_transcript, "## Summary\nA great meeting.")

        # The summary used to be written to summary.json as raw markdown.
        assert json.loads(summary_str)["summary"] == "## Summary\nA great meeting."

    def test_json_summary_written_to_disk_parses(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "json"
        config.summarization.enabled = True
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = TranscriptResult(
            segments=[Segment(text="Hello world.", start=0.0, end=1.5)],
            language="en",
            duration=1.5,
        )

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = ""

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=True)

        written = json.loads((tmp_path / "summary.json").read_text())
        assert written["summary"] == "## Summary\nGood meeting."


class TestSlugify:
    def test_basic(self):
        from ownscribe.pipeline import _slugify

        assert _slugify("Q3 Budget Planning Review") == "q3-budget-planning-review"

    def test_strips_special_chars(self):
        from ownscribe.pipeline import _slugify

        assert _slugify("Hello, World! @#$") == "hello-world"

    def test_truncates_to_max_length(self):
        from ownscribe.pipeline import _slugify

        result = _slugify("a " * 100, max_length=10)
        assert len(result) <= 10

    def test_empty_input(self):
        from ownscribe.pipeline import _slugify

        assert _slugify("") == ""

    def test_colons_removed(self):
        from ownscribe.pipeline import _slugify

        assert _slugify("Meeting: Budget Review") == "meeting-budget-review"


class TestGenerateTitleSlug:
    def test_returns_slug(self):
        from ownscribe.pipeline import _generate_title_slug

        mock_summarizer = mock.MagicMock()
        mock_summarizer.generate_title.return_value = "Budget Review"

        assert _generate_title_slug("summary text", mock_summarizer) == "budget-review"

    def test_returns_empty_on_empty_slug(self):
        from ownscribe.pipeline import _generate_title_slug

        mock_summarizer = mock.MagicMock()
        mock_summarizer.generate_title.return_value = "!!!"  # slugifies to empty

        assert _generate_title_slug("summary", mock_summarizer) == ""

    def test_returns_empty_on_llm_failure(self):
        from ownscribe.pipeline import _generate_title_slug

        mock_summarizer = mock.MagicMock()
        mock_summarizer.generate_title.side_effect = Exception("LLM down")

        assert _generate_title_slug("summary", mock_summarizer) == ""


class TestRenameOutputDir:
    def test_renames_when_target_does_not_exist(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "2026-01-01_1200"
        source.mkdir()
        (source / "transcript.md").write_text("hi")

        result = _rename_output_dir(source, "budget-review")

        expected = tmp_path / "2026-01-01_1200_budget-review"
        assert result == expected
        assert expected.exists()
        assert not source.exists()

    def test_skips_cleanly_when_target_exists_with_content(self, tmp_path, caplog):
        from pathlib import Path

        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "2026-01-01_1200"
        source.mkdir()
        (source / "transcript.md").write_text("hi")

        target = tmp_path / "2026-01-01_1200_budget-review"
        target.mkdir()
        (target / "unrelated.txt").write_text("already here")

        with mock.patch.object(Path, "rename") as mock_rename, caplog.at_level(logging.DEBUG):
            result = _rename_output_dir(source, "budget-review")

        mock_rename.assert_not_called()
        assert not [record for record in caplog.records if record.levelno >= logging.WARNING]
        assert result == source
        assert source.exists()
        assert (target / "unrelated.txt").read_text() == "already here"

    def test_renames_when_target_exists_but_is_empty(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "2026-01-01_1200"
        source.mkdir()
        (source / "transcript.md").write_text("hi")

        target = tmp_path / "2026-01-01_1200_budget-review"
        target.mkdir()

        result = _rename_output_dir(source, "budget-review")

        assert result == target
        assert (target / "transcript.md").read_text() == "hi"

    def test_returns_original_on_unexpected_os_error(self, tmp_path, caplog):
        from pathlib import Path

        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "2026-01-01_1200"
        source.mkdir()

        with (
            mock.patch.object(Path, "rename", side_effect=OSError("cross-device link")),
            caplog.at_level(logging.DEBUG),
        ):
            result = _rename_output_dir(source, "budget-review")

        assert result == source
        assert source.exists()
        warnings = [record for record in caplog.records if record.levelno == logging.WARNING]
        assert len(warnings) == 1
        assert "cross-device link" in warnings[0].getMessage()
        # exc_info would print a traceback to stderr, which reads like a crash.
        assert warnings[0].exc_info is None

    def test_returns_original_when_target_is_a_file(self, tmp_path, caplog):
        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "2026-01-01_1200"
        source.mkdir()
        (source / "transcript.md").write_text("hi")

        target = tmp_path / "2026-01-01_1200_budget-review"
        target.write_text("not a directory")

        with caplog.at_level(logging.DEBUG):
            result = _rename_output_dir(source, "budget-review")

        assert result == source
        assert (source / "transcript.md").read_text() == "hi"
        assert target.read_text() == "not a directory"
        assert [record for record in caplog.records if record.levelno == logging.WARNING]


class TestDoTranscribeAndSummarize:
    """Test _do_transcribe_and_summarize with mocked transcriber/summarizer."""

    def _make_transcript(self) -> TranscriptResult:
        return TranscriptResult(
            segments=[Segment(text="Hello world.", start=0.0, end=1.5)],
            language="en",
            duration=1.5,
        )

    def test_summarizer_receives_speaker_labels(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.summarization.enabled = True
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = TranscriptResult(
            segments=[
                Segment(text="Let's start.", start=0.0, end=1.0, speaker="SPEAKER_00"),
                Segment(text="I'll take the deploy.", start=1.0, end=2.5, speaker="SPEAKER_01"),
            ],
            language="en",
            duration=2.5,
        )

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=True)

        summarized = mock_summarizer.summarize.call_args[0][0]
        assert summarized == "SPEAKER_00: Let's start.\nSPEAKER_01: I'll take the deploy."

    def test_transcribe_only(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        with mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=False)

        assert (tmp_path / "transcript.md").exists()
        assert not (tmp_path / "summary.md").exists()

    def test_transcribe_and_summarize(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.summarization.enabled = True
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=True)

        assert (tmp_path / "transcript.md").exists()
        assert (tmp_path / "summary.md").exists()
        assert "Summary" in (tmp_path / "summary.md").read_text()

    def test_summarizer_unavailable_skips_gracefully(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.summarization.enabled = True
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = "oMLX is not reachable at http://127.0.0.1:8000/v1. Is it running?"

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
        ):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=True)

        assert (tmp_path / "transcript.md").exists()
        assert not (tmp_path / "summary.md").exists()

    def test_json_output_format(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "json"
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        with mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=False)

        assert (tmp_path / "transcript.json").exists()
        assert not (tmp_path / "transcript.md").exists()

    def test_keep_recording_false_deletes_wav(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.output.keep_recording = False
        audio_path = tmp_path / "recording.wav"
        audio_path.write_bytes(b"fake audio data")

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        with mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=False)

        assert (tmp_path / "transcript.md").exists()
        assert not audio_path.exists()

    def test_keep_recording_true_keeps_wav(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.output.keep_recording = True
        audio_path = tmp_path / "recording.wav"
        audio_path.write_bytes(b"fake audio data")

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        with mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=False)

        assert (tmp_path / "transcript.md").exists()
        assert audio_path.exists()

    def test_summarization_failure_preserves_transcript(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.summarization.enabled = True
        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.side_effect = Exception("GPU OOM")

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, tmp_path, summarize=True)

        assert (tmp_path / "transcript.md").exists()
        assert "Hello world." in (tmp_path / "transcript.md").read_text()
        assert not (tmp_path / "summary.md").exists()

    def test_separate_audio_dir_renamed_alongside_out_dir(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.summarization.enabled = True
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        out_dir = tmp_path / "notes" / "2026-01-01_1200"
        out_dir.mkdir(parents=True)
        audio_dir = tmp_path / "audio-cache" / "2026-01-01_1200"
        audio_dir.mkdir(parents=True)
        audio_path = audio_dir / "recording.wav"
        audio_path.write_bytes(b"fake audio data")

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = "Budget Review"

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, out_dir, summarize=True)

        renamed_out_dir = out_dir.parent / "2026-01-01_1200_budget-review"
        renamed_audio_dir = audio_dir.parent / "2026-01-01_1200_budget-review"
        assert (renamed_out_dir / "transcript.md").exists()
        assert (renamed_out_dir / "summary.md").exists()
        assert (renamed_audio_dir / "recording.wav").exists()
        assert not out_dir.exists()
        assert not audio_dir.exists()

    def test_keep_recording_false_deletes_from_separate_audio_dir(self, tmp_path):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.output.keep_recording = False
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        out_dir = tmp_path / "notes" / "2026-01-01_1200"
        out_dir.mkdir(parents=True)
        audio_dir = tmp_path / "audio-cache" / "2026-01-01_1200"
        audio_dir.mkdir(parents=True)
        audio_path = audio_dir / "recording.wav"
        audio_path.write_bytes(b"fake audio data")

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        with mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber):
            _do_transcribe_and_summarize(config, audio_path, out_dir, summarize=False)

        assert (out_dir / "transcript.md").exists()
        assert not audio_path.exists()
        assert not audio_dir.exists()

    def test_colocated_audio_follows_rename_despite_separate_audio_dir(self, tmp_path):
        """Resuming a directory that holds its own recording (made before
        audio_dir was configured) must follow out_dir's rename, not try to
        rename the audio's directory a second time."""
        from ownscribe.pipeline import _do_transcribe_and_summarize

        config = Config()
        config.output.format = "markdown"
        config.output.keep_recording = False
        config.summarization.enabled = True
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        out_dir = tmp_path / "notes" / "2026-01-01_1200"
        out_dir.mkdir(parents=True)
        audio_path = out_dir / "recording.wav"
        audio_path.write_bytes(b"fake audio data")

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = self._make_transcript()

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = "Budget Review"

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, out_dir, summarize=True)

        renamed_out_dir = out_dir.parent / "2026-01-01_1200_budget-review"
        assert (renamed_out_dir / "transcript.md").exists()
        assert (renamed_out_dir / "summary.md").exists()
        assert not (renamed_out_dir / "recording.wav").exists()
        assert not out_dir.exists()


class TestRunWarmup:
    def test_run_warmup_calls_prepare_models(self):
        from ownscribe.pipeline import run_warmup

        config = Config()
        config.transcription.language = "en"

        mock_transcriber = mock.MagicMock()

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            run_warmup(config)

        mock_transcriber.prepare_models.assert_called_once_with(language="en")

    def test_run_warmup_enables_prepare_step_in_progress(self):
        from ownscribe.pipeline import run_warmup

        config = Config()
        mock_transcriber = mock.MagicMock()
        fake_progress = mock.MagicMock()

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline.PipelineProgress") as mock_progress_cls,
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
            # The default model is often already cached on a developer machine,
            # which would hide the download step this test expects.
            mock.patch("ownscribe.summarization.llama_cpp_summarizer.is_model_cached", return_value=False),
        ):
            mock_progress_cls.return_value.__enter__.return_value = fake_progress
            run_warmup(config)

        _, kwargs = mock_progress_cls.call_args
        assert kwargs["include_prepare"] is True
        assert kwargs["transcribe"] is False
        assert kwargs["download_summarizer"] is True

    def test_run_warmup_downloads_summarizer_with_progress(self):
        from ownscribe.pipeline import run_warmup

        config = Config()
        config.summarization.enabled = True
        config.summarization.backend = "local"
        config.summarization.model = "phi-4-mini"

        mock_transcriber = mock.MagicMock()

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model") as mock_ensure,
        ):
            run_warmup(config)

        mock_ensure.assert_called_once()
        _, kwargs = mock_ensure.call_args
        assert kwargs.get("on_progress") is not None

    def test_run_warmup_skips_summarizer_download_when_not_local(self):
        from ownscribe.pipeline import run_warmup

        config = Config()
        config.summarization.enabled = True
        config.summarization.backend = "ollama"

        mock_transcriber = mock.MagicMock()

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model") as mock_ensure,
        ):
            run_warmup(config)

        mock_ensure.assert_not_called()


class TestRunPipelineAudioLocation:
    """Test that run_pipeline records into the configured audio_dir."""

    def _make_recorder_mock(self):
        recorder = mock.MagicMock()
        recorder.is_recording = False  # skip the recording loop immediately
        recorder.is_muted = False
        recorder.silence_timed_out = False
        recorder.silence_warning = False

        def _start(path):
            # Must exceed _WAV_HEADER_SIZE (44 bytes) or run_pipeline treats it as empty.
            path.write_bytes(b"fake audio data, definitely more than 44 bytes")

        recorder.start.side_effect = _start
        return recorder

    def test_audio_recorded_into_separate_audio_dir(self, tmp_path):
        from ownscribe.pipeline import run_pipeline

        config = Config()
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        mock_recorder = self._make_recorder_mock()

        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=mock_recorder),
            mock.patch("ownscribe.pipeline._do_transcribe_and_summarize") as mock_ts,
        ):
            run_pipeline(config)

        # The recorder was pointed at a file under audio_dir, not dir.
        audio_path = mock_recorder.start.call_args[0][0]
        assert audio_path.is_relative_to(tmp_path / "audio-cache")
        assert not audio_path.is_relative_to(tmp_path / "notes")
        assert audio_path.exists()

        # Downstream processing still receives the audio dir's out_dir counterpart.
        called_audio_path, called_out_dir = mock_ts.call_args[0][1], mock_ts.call_args[0][2]
        assert called_audio_path == audio_path
        assert called_out_dir.is_relative_to(tmp_path / "notes")
        assert called_out_dir.name == audio_path.parent.name

    def test_no_audio_captured_hints_at_no_mic(self, tmp_path, capsys):
        from ownscribe.pipeline import run_pipeline

        config = Config()
        config.output.dir = str(tmp_path / "notes")

        recorder = self._make_recorder_mock()
        recorder.start.side_effect = lambda path: path.write_bytes(b"")

        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=recorder),
            contextlib.suppress(SystemExit),
        ):
            run_pipeline(config)

        assert "--no-mic" in capsys.readouterr().err

    def test_no_audio_captured_without_mic_omits_hint(self, tmp_path, capsys):
        from ownscribe.pipeline import run_pipeline

        config = Config()
        config.output.dir = str(tmp_path / "notes")
        config.audio.mic = False

        recorder = self._make_recorder_mock()
        recorder.start.side_effect = lambda path: path.write_bytes(b"")

        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=recorder),
            contextlib.suppress(SystemExit),
        ):
            run_pipeline(config)

        assert "--no-mic" not in capsys.readouterr().err

    def test_audio_recorded_into_dir_when_audio_dir_unset(self, tmp_path):
        from ownscribe.pipeline import run_pipeline

        config = Config()
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = ""

        mock_recorder = self._make_recorder_mock()

        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=mock_recorder),
            mock.patch("ownscribe.pipeline._do_transcribe_and_summarize"),
        ):
            run_pipeline(config)

        audio_path = mock_recorder.start.call_args[0][0]
        assert audio_path.is_relative_to(tmp_path / "notes")
        assert audio_path.parent.parent == tmp_path / "notes"


class TestRunTranscribeColocation:
    """Test that run_transcribe saves output alongside the input file."""

    def test_transcript_saved_next_to_audio(self, tmp_path):
        from ownscribe.pipeline import run_transcribe

        audio_dir = tmp_path / "meetings" / "2026-01-01_1200"
        audio_dir.mkdir(parents=True)
        audio_path = audio_dir / "recording.wav"
        audio_path.touch()

        config = Config()
        config.output.format = "markdown"

        mock_transcriber = mock.MagicMock()
        mock_transcriber.transcribe.return_value = TranscriptResult(
            segments=[Segment(text="Test.", start=0.0, end=1.0)],
            language="en",
            duration=1.0,
        )

        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=mock_transcriber),
            mock.patch("ownscribe.pipeline._check_audio_silence"),
        ):
            run_transcribe(config, str(audio_path))

        assert (audio_dir / "transcript.md").exists()


class TestRunSummarizeTranscriptText:
    """run_summarize must normalise the saved transcript, not paste the file in."""

    @staticmethod
    def _summarize(config, tx_path):
        from ownscribe.pipeline import run_summarize

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = ""

        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            run_summarize(config, str(tx_path))

        return mock_summarizer.summarize.call_args[0][0]

    def test_markdown_timestamps_are_stripped(self, tmp_path):
        from ownscribe.output.markdown import format_transcript

        tx_path = tmp_path / "transcript.md"
        tx_path.write_text(
            format_transcript(
                TranscriptResult(
                    segments=[
                        Segment(text="Let's start.", start=0.0, end=1.0, speaker="SPEAKER_00"),
                        Segment(text="Agreed.", start=1.0, end=2.0, speaker="SPEAKER_01"),
                    ],
                    language="en",
                    duration=2.0,
                )
            )
        )

        summarized = self._summarize(Config(), tx_path)

        assert summarized == "SPEAKER_00: Let's start.\nSPEAKER_01: Agreed."
        assert "[00:00]" not in summarized
        assert "# Transcript" not in summarized

    def test_json_transcript_is_not_handed_to_the_llm_raw(self, tmp_path):
        from ownscribe.output.json_output import format_transcript_json
        from ownscribe.transcription.models import Word

        tx_path = tmp_path / "transcript.json"
        tx_path.write_text(
            format_transcript_json(
                TranscriptResult(
                    segments=[
                        Segment(
                            text="Budget is approved.",
                            start=0.0,
                            end=2.0,
                            speaker="SPEAKER_00",
                            words=[Word(text="Budget", start=0.0, end=0.4, score=0.98)],
                        )
                    ],
                    language="en",
                    duration=2.0,
                )
            )
        )

        summarized = self._summarize(Config(), tx_path)

        assert summarized == "SPEAKER_00: Budget is approved."
        assert "score" not in summarized
        assert "segments" not in summarized

    def test_plain_text_file_is_passed_through(self, tmp_path):
        tx_path = tmp_path / "notes.txt"
        tx_path.write_text("Just some notes I typed myself.")

        assert self._summarize(Config(), tx_path) == "Just some notes I typed myself."


class TestRunSummarizeProblem:
    def test_prints_the_reason_and_writes_nothing(self, tmp_path, capsys):
        from ownscribe.pipeline import run_summarize

        transcript = tmp_path / "transcript.md"
        transcript.write_text("# Transcript\n\n[00:00] Hello.\n")
        summarizer = mock.MagicMock()
        summarizer.problem.return_value = "oMLX refused the API key (summarization.api_key or OPENAI_API_KEY)."
        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=summarizer),
            pytest.raises(SystemExit) as exit_info,
        ):
            run_summarize(Config(), str(transcript))

        assert exit_info.value.code == 1
        assert "Error: oMLX refused the API key" in capsys.readouterr().err
        assert not (tmp_path / "summary.md").exists()
        summarizer.summarize.assert_not_called()


class TestRunSummarizeColocation:
    """Test that run_summarize saves output alongside the input file."""

    def test_summary_saved_next_to_transcript(self, tmp_path):
        from ownscribe.pipeline import run_summarize

        tx_dir = tmp_path / "meetings" / "2026-01-01_1200"
        tx_dir.mkdir(parents=True)
        tx_path = tx_dir / "transcript.md"
        tx_path.write_text("# Transcript\nHello world.")

        config = Config()
        config.summarization.enabled = True

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = "test-title"

        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            run_summarize(config, str(tx_path))

        renamed_dir = tx_dir.parent / f"{tx_dir.name}_test-title"
        assert (renamed_dir / "summary.md").exists()

    def test_renames_matching_audio_dir_inside_output_tree(self, tmp_path):
        from ownscribe.pipeline import run_summarize

        tx_dir = tmp_path / "notes" / "2026-01-01_1200"
        tx_dir.mkdir(parents=True)
        tx_path = tx_dir / "transcript.md"
        tx_path.write_text("# Transcript\nHello world.")

        audio_dir = tmp_path / "audio-cache" / "2026-01-01_1200"
        audio_dir.mkdir(parents=True)
        (audio_dir / "recording.wav").write_bytes(b"fake audio data")

        config = Config()
        config.summarization.enabled = True
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = "test-title"

        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            run_summarize(config, str(tx_path))

        renamed_audio_dir = audio_dir.parent / f"{audio_dir.name}_test-title"
        assert (renamed_audio_dir / "recording.wav").exists()
        assert not audio_dir.exists()

    def test_leaves_audio_dir_alone_for_transcript_outside_output_tree(self, tmp_path):
        """A same-named directory under audio_dir must not be renamed when the
        summarized transcript does not belong to the output tree."""
        from ownscribe.pipeline import run_summarize

        tx_dir = tmp_path / "elsewhere" / "2026-01-01_1200"
        tx_dir.mkdir(parents=True)
        tx_path = tx_dir / "transcript.md"
        tx_path.write_text("# Transcript\nHello world.")

        unrelated_audio_dir = tmp_path / "audio-cache" / "2026-01-01_1200"
        unrelated_audio_dir.mkdir(parents=True)

        config = Config()
        config.summarization.enabled = True
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        mock_summarizer = mock.MagicMock()
        mock_summarizer.problem.return_value = None
        mock_summarizer.summarize.return_value = "## Summary\nGood meeting."
        mock_summarizer.generate_title.return_value = "test-title"

        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=mock_summarizer),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            run_summarize(config, str(tx_path))

        renamed_dir = tx_dir.parent / f"{tx_dir.name}_test-title"
        assert (renamed_dir / "summary.md").exists()
        assert unrelated_audio_dir.exists()
        assert not (unrelated_audio_dir.parent / f"{tx_dir.name}_test-title").exists()


class TestResume:
    """Test run_resume artifact detection and dispatch."""

    def test_nothing_to_resume(self, tmp_path):
        from ownscribe.pipeline import run_resume

        (tmp_path / "transcript.md").write_text("hello")
        (tmp_path / "summary.md").write_text("summary")

        config = Config()
        run_resume(config, str(tmp_path))
        # Should exit cleanly without error

    def test_error_no_audio_no_transcript(self, tmp_path):
        from ownscribe.pipeline import run_resume

        config = Config()
        with mock.patch("sys.exit", side_effect=SystemExit(1)), contextlib.suppress(SystemExit):
            run_resume(config, str(tmp_path))

    def test_resumes_summarize_only(self, tmp_path):
        from ownscribe.pipeline import run_resume

        (tmp_path / "transcript.md").write_text("# Transcript\nHello.")

        config = Config()
        config.summarization.enabled = True

        with mock.patch("ownscribe.pipeline.run_summarize") as mock_sum:
            run_resume(config, str(tmp_path))
            mock_sum.assert_called_once_with(config, str(tmp_path / "transcript.md"))

    def test_resumes_transcribe_and_summarize(self, tmp_path):
        from ownscribe.pipeline import run_resume

        audio_path = tmp_path / "recording.wav"
        audio_path.touch()

        config = Config()

        with mock.patch("ownscribe.pipeline._do_transcribe_and_summarize") as mock_ts:
            run_resume(config, str(tmp_path))
            mock_ts.assert_called_once_with(config, audio_path, tmp_path)

    def test_finds_non_wav_audio(self, tmp_path):
        from ownscribe.pipeline import run_resume

        audio_path = tmp_path / "meeting.mp3"
        audio_path.touch()

        config = Config()

        with mock.patch("ownscribe.pipeline._do_transcribe_and_summarize") as mock_ts:
            run_resume(config, str(tmp_path))
            mock_ts.assert_called_once_with(config, audio_path, tmp_path)

    def test_finds_audio_in_separate_audio_dir(self, tmp_path):
        from ownscribe.pipeline import run_resume

        text_dir = tmp_path / "notes" / "2026-01-01_1200"
        text_dir.mkdir(parents=True)
        audio_dir = tmp_path / "audio-cache" / "2026-01-01_1200"
        audio_dir.mkdir(parents=True)
        audio_path = audio_dir / "recording.wav"
        audio_path.touch()

        config = Config()
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio-cache")

        with mock.patch("ownscribe.pipeline._do_transcribe_and_summarize") as mock_ts:
            run_resume(config, str(text_dir))
            mock_ts.assert_called_once_with(config, audio_path, text_dir)

    def test_finds_json_transcript(self, tmp_path):
        from ownscribe.pipeline import run_resume

        (tmp_path / "transcript.json").write_text('{"segments": []}')

        config = Config()

        with mock.patch("ownscribe.pipeline.run_summarize") as mock_sum:
            run_resume(config, str(tmp_path))
            mock_sum.assert_called_once_with(config, str(tmp_path / "transcript.json"))


class TestRunDirectoryNaming:
    """Run folders are YYMMDD-HHMM, or YYMMDD-{title} when a title is known."""

    @staticmethod
    def _config(tmp_path):
        from ownscribe.config import Config

        cfg = Config()
        cfg.output.dir = str(tmp_path)
        return cfg

    def test_untitled_run_uses_date_and_time(self, tmp_path):
        from ownscribe.pipeline import _get_output_dir

        out = _get_output_dir(self._config(tmp_path))

        assert re.fullmatch(r"\d{6}-\d{4}", out.name), out.name

    def test_title_replaces_the_time(self, tmp_path):
        from ownscribe.pipeline import _get_output_dir

        out = _get_output_dir(self._config(tmp_path), "Q2 Sales Review")

        assert re.fullmatch(r"\d{6}-q2-sales-review", out.name), out.name

    def test_same_title_same_day_does_not_collide(self, tmp_path):
        """A standup recorded twice in one day must not reuse the first folder."""
        from ownscribe.pipeline import _get_output_dir

        cfg = self._config(tmp_path)
        first = _get_output_dir(cfg, "Standup")
        (first / "transcript.md").write_text("first meeting")
        second = _get_output_dir(cfg, "Standup")

        assert first != second
        # the first one keeps the clean name and its content
        assert (first / "transcript.md").read_text() == "first meeting"
        assert second.name.startswith(first.name)

    def test_blank_or_punctuation_only_title_falls_back_to_time(self, tmp_path):
        from ownscribe.pipeline import _get_output_dir

        cfg = self._config(tmp_path)
        for title in ("", "   ", "!!!"):
            out = _get_output_dir(cfg, title)
            # HHMM, or HHMMSS when an earlier run already claimed this minute.
            assert re.fullmatch(r"\d{6}-\d{4}(\d{2})?", out.name), (title, out.name)

    def test_generated_title_replaces_the_time_on_rename(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        d = tmp_path / "260827-1400"
        d.mkdir()

        renamed = _rename_output_dir(d, "q2-sales-review")

        assert renamed.name == "260827-q2-sales-review"
        assert not d.exists()

    def test_rename_collision_keeps_the_time(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        occupied = tmp_path / "260827-standup"
        occupied.mkdir()
        (occupied / "transcript.md").write_text("the earlier standup")
        d = tmp_path / "260827-1630"
        d.mkdir()

        renamed = _rename_output_dir(d, "standup")

        assert renamed.name == "260827-standup_1630"
        # an *empty* leftover, by contrast, is fine to reuse
        assert (occupied / "transcript.md").read_text() == "the earlier standup"

    def test_title_ending_in_digits_is_not_confused_with_a_time(self, tmp_path):
        """`260827-budget-2026` must stay a title; hence `_` for the collision suffix."""
        from ownscribe.pipeline import _get_output_dir

        cfg = self._config(tmp_path)
        first = _get_output_dir(cfg, "Budget 2026")
        (first / "t.md").write_text("x")
        second = _get_output_dir(cfg, "Budget 2026")

        assert first.name.endswith("-budget-2026")
        assert "_" in second.name and second.name.startswith(first.name + "_")

    def test_legacy_directories_keep_their_format(self, tmp_path):
        """Folders from before this scheme must not be reformatted under the user."""
        from ownscribe.pipeline import _rename_output_dir

        d = tmp_path / "2026-08-27_1400"
        d.mkdir()

        renamed = _rename_output_dir(d, "q2-sales-review")

        assert renamed.name == "2026-08-27_1400_q2-sales-review"

    def test_force_name_keeps_a_separate_audio_dir_in_step(self, tmp_path):
        """Recomputing the name could pick a different collision suffix and desync."""
        from ownscribe.pipeline import _rename_output_dir

        audio = tmp_path / "260827-1630"
        audio.mkdir()
        (tmp_path / "260827-standup").mkdir()  # would push a recompute to the -1630 variant

        renamed = _rename_output_dir(audio, "standup", force_name="260827-standup_9999")

        assert renamed.name == "260827-standup_9999"

    def test_rename_never_destroys_an_existing_directory(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        for name in ("260827-standup", "260827-standup_1630"):
            occupied = tmp_path / name
            occupied.mkdir()
            (occupied / "keep.md").write_text(name)
        d = tmp_path / "260827-1630"
        d.mkdir()

        renamed = _rename_output_dir(d, "standup")

        assert renamed == d  # gave up rather than clobber
        for name in ("260827-standup", "260827-standup_1630"):
            assert (tmp_path / name / "keep.md").read_text() == name


class TestSecretPresenceReporting:
    """`config get` blanks secrets; a UI still needs to know one is stored."""

    def test_reports_which_secrets_are_set_without_revealing_them(self):
        from ownscribe.config import Config
        from ownscribe.config_io import config_to_dict

        cfg = Config()
        cfg.diarization.hf_token = "hf_realsecret"

        data = config_to_dict(cfg)

        assert data["diarization"]["hf_token"] == ""
        assert data["secrets_set"]["diarization.hf_token"] is True
        assert data["secrets_set"]["summarization.api_key"] is False
        assert "hf_realsecret" not in json.dumps(data)

    def test_reveal_secrets_still_returns_the_value(self):
        from ownscribe.config import Config
        from ownscribe.config_io import config_to_dict

        cfg = Config()
        cfg.diarization.hf_token = "hf_realsecret"

        data = config_to_dict(cfg, reveal_secrets=True)

        assert data["diarization"]["hf_token"] == "hf_realsecret"


class TestReviewFixes:
    """Findings from the external review of a6eb811."""

    def test_untitled_runs_in_the_same_minute_do_not_share_a_directory(self, tmp_path):
        """mkdir(exist_ok=True) let a second start overwrite the first recording."""
        from ownscribe.config import Config
        from ownscribe.pipeline import _get_output_dir

        cfg = Config()
        cfg.output.dir = str(tmp_path)
        first = _get_output_dir(cfg)
        (first / "recording.wav").write_text("first meeting")
        second = _get_output_dir(cfg)

        assert first != second
        assert (first / "recording.wav").read_text() == "first meeting"

    def test_find_audio_is_deterministic(self, tmp_path):
        from ownscribe.pipeline import _find_audio

        for name in ("b.mp4", "a.mp3", "c.mov"):
            (tmp_path / name).write_text("x")

        assert _find_audio(tmp_path).name == "a.mp3"

    def test_unknown_summarizer_backend_fails_loudly(self):
        """It used to fall through to Ollama and only fail after the meeting."""
        import pytest

        from ownscribe.config import Config
        from ownscribe.summarization import create_summarizer

        cfg = Config()
        cfg.summarization.backend = "opneai"
        with pytest.raises(ValueError, match="Unknown summarization backend"):
            create_summarizer(cfg)

    def test_bad_backend_is_rejected_before_recording(self):
        import click
        import pytest

        from ownscribe.config import Config
        from ownscribe.pipeline import _validate_backends

        cfg = Config()
        cfg.summarization.enabled = True
        cfg.summarization.backend = "llama"
        with pytest.raises(click.ClickException):
            _validate_backends(cfg)


class TestConfigCoercion:
    """Hand-edited TOML went in untyped; `config set` coerced but load() did not."""

    @staticmethod
    def _load(tmp_path, monkeypatch, body: str):
        from ownscribe import config as cfgmod

        path = tmp_path / "config.toml"
        path.write_text(body)
        monkeypatch.setattr(cfgmod, "CONFIG_PATH", path)
        # Config.load() lets these override the file; a developer's shell often
        # sets HF_TOKEN, which would then decide what the TOML assertions see.
        for name in ("HF_TOKEN", "OLLAMA_HOST", "OPENAI_API_KEY"):
            monkeypatch.delenv(name, raising=False)
        return cfgmod.Config.load()

    def test_string_false_is_not_truthy(self, tmp_path, monkeypatch):
        """`mic = "false"` used to leave the microphone on."""
        cfg = self._load(tmp_path, monkeypatch, '[audio]\nmic = "false"\n')

        assert cfg.audio.mic is False

    def test_numeric_string_is_coerced(self, tmp_path, monkeypatch):
        cfg = self._load(tmp_path, monkeypatch, '[audio]\nsilence_timeout = "300"\n')

        assert cfg.audio.silence_timeout == 300

    def test_nonsense_value_is_rejected(self, tmp_path, monkeypatch):
        import pytest

        with pytest.raises(ValueError, match="silence_timeout"):
            self._load(tmp_path, monkeypatch, '[audio]\nsilence_timeout = "soon"\n')

    def test_invalid_enum_is_rejected(self, tmp_path, monkeypatch):
        import pytest

        with pytest.raises(ValueError, match=r"output\.format"):
            self._load(tmp_path, monkeypatch, '[output]\nformat = "yaml"\n')

    def test_unknown_key_warns_instead_of_vanishing(self, tmp_path, monkeypatch, capsys):
        cfg = self._load(tmp_path, monkeypatch, '[diarization]\nhf_tokn = "oops"\n')

        assert "hf_tokn" in capsys.readouterr().err
        assert cfg.diarization.hf_token == ""

    def test_valid_config_still_loads(self, tmp_path, monkeypatch):
        cfg = self._load(
            tmp_path,
            monkeypatch,
            "[audio]\nmic = true\nsilence_timeout = 60\n"
            '[output]\nformat = "json"\n[summarization]\nbackend = "ollama"\n',
        )

        assert cfg.audio.mic is True
        assert cfg.audio.silence_timeout == 60
        assert cfg.output.format == "json"
        assert cfg.summarization.backend == "ollama"


class TestSecondsDisambiguatedDirectories:
    """A run directory that fell back to HHMMSS must still be renameable."""

    def test_a_generated_title_can_rename_it(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        d = tmp_path / "260902-140233"
        d.mkdir()

        renamed = _rename_output_dir(d, "q2-sales-review")

        assert renamed.name == "260902-q2-sales-review"

    def test_its_collision_suffix_uses_the_minute(self, tmp_path):
        from ownscribe.pipeline import _rename_output_dir

        occupied = tmp_path / "260902-standup"
        occupied.mkdir()
        (occupied / "t.md").write_text("earlier")
        d = tmp_path / "260902-140233"
        d.mkdir()

        assert _rename_output_dir(d, "standup").name == "260902-standup_1402"


class TestMeetingSavedEvent:
    """meeting_saved closes every successful run and names the final folder."""

    @staticmethod
    def _events(capsys) -> list[dict]:
        events = []
        for line in capsys.readouterr().err.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and "ownscribe_progress" in obj:
                events.append(obj)
        return events

    @staticmethod
    def _summarizer(*, available: bool = True, fails: bool = False, title: str = "Q2 Sales Review"):
        summarizer = mock.MagicMock()
        unreachable = "Ollama is not reachable at http://localhost:11434. Is it running?"
        summarizer.problem.return_value = None if available else unreachable
        if fails:
            summarizer.summarize.side_effect = RuntimeError("model crashed")
        else:
            summarizer.summarize.return_value = "## Summary\nGood meeting."
        summarizer.generate_title.return_value = title
        return summarizer

    def _transcribe(self, tmp_path, config: Config, summarizer=None):
        from ownscribe.pipeline import _do_transcribe_and_summarize

        out_dir = tmp_path / "notes" / "260101-1200"
        out_dir.mkdir(parents=True)
        audio_path = out_dir / "recording.wav"
        audio_path.write_bytes(b"audio")
        transcriber = mock.MagicMock()
        transcriber.transcribe.return_value = TranscriptResult(
            segments=[Segment(text="Hello.", start=0.0, end=1.0)], language="en", duration=1.0
        )
        with (
            mock.patch("ownscribe.pipeline._create_transcriber", return_value=transcriber),
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=summarizer or self._summarizer()),
            mock.patch("ownscribe.pipeline._needs_model_download", return_value=False),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            _do_transcribe_and_summarize(config, audio_path, out_dir)
        return out_dir

    def test_last_event_carries_the_renamed_folder(self, tmp_path, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        out_dir = self._transcribe(tmp_path, Config())

        events = self._events(capsys)
        assert events[-1]["event"] == "meeting_saved"
        assert events[-1]["folder"] == str(out_dir.parent / "260101-q2-sales-review")
        assert events[-1]["summary"] == "ok"

    def test_summarization_disabled(self, tmp_path, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        config = Config()
        config.summarization.enabled = False
        out_dir = self._transcribe(tmp_path, config)

        saved = self._events(capsys)[-1]
        assert saved == {**saved, "event": "meeting_saved", "folder": str(out_dir), "summary": "disabled"}

    def test_summarizer_unavailable(self, tmp_path, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        self._transcribe(tmp_path, Config(), self._summarizer(available=False))

        assert self._events(capsys)[-1]["summary"] == "unavailable"

    def test_unavailable_summarizer_says_why_and_keeps_the_transcript(self, tmp_path, capsys):
        out_dir = self._transcribe(tmp_path, Config(), self._summarizer(available=False))

        assert (out_dir / "transcript.md").is_file()
        assert not (out_dir / "summary.md").exists()
        assert "Ollama is not reachable at http://localhost:11434. Is it running?" in capsys.readouterr().err

    def test_a_new_summary_records_what_it_was_written_with(self, tmp_path):
        from ownscribe.meeting_meta import read_meta, summary_request

        config = Config()
        config.summarization.template = "brief"
        # No title, so the folder keeps the name _transcribe returns.
        out_dir = self._transcribe(tmp_path, config, self._summarizer(title=""))

        assert summary_request(out_dir, read_meta(out_dir)) == {
            "backend": "local",
            "model": "phi-4-mini",
            "template": "brief",
            "instructions": "",
        }

    def test_summary_failed(self, tmp_path, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        out_dir = self._transcribe(tmp_path, Config(), self._summarizer(fails=True))

        saved = self._events(capsys)[-1]
        assert saved["summary"] == "failed"
        assert saved["folder"] == str(out_dir)

    def test_summarize_only_resume(self, tmp_path, capsys, monkeypatch):
        from ownscribe.pipeline import run_resume

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        folder = tmp_path / "notes" / "260101-1200"
        folder.mkdir(parents=True)
        (folder / "transcript.md").write_text("# Transcript\n\n[00:00] Hello.\n")
        config = Config()
        config.output.dir = str(tmp_path / "notes")

        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=self._summarizer()),
            mock.patch("ownscribe.pipeline._needs_model_download", return_value=False),
            mock.patch("ownscribe.summarization.llama_cpp_summarizer._ensure_model"),
        ):
            run_resume(config, str(folder))

        saved = self._events(capsys)[-1]
        assert saved["event"] == "meeting_saved"
        assert saved["folder"] == str(folder.parent / "260101-q2-sales-review")
        assert saved["summary"] == "ok"

    def test_nothing_to_resume(self, tmp_path, capsys, monkeypatch):
        from ownscribe.pipeline import run_resume

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        (tmp_path / "transcript.md").write_text("# Transcript\n\n[00:00] Hello.\n")
        (tmp_path / "summary.md").write_text("# Meeting Summary\n\nDone.\n")

        run_resume(Config(), str(tmp_path))

        assert self._events(capsys) == [
            {"ownscribe_progress": 1, "event": "meeting_saved", "folder": str(tmp_path), "summary": "ok"}
        ]


class TestFolderLocking:
    """A recording run and resume hold the meeting folder's lock while they work."""

    def test_recording_holds_the_folder_lock_until_the_meeting_is_saved(self, tmp_path):
        from ownscribe.locks import LockState, probe
        from ownscribe.pipeline import run_pipeline

        config = Config()
        config.output.dir = str(tmp_path / "notes")
        seen: list[LockState] = []

        recorder = TestRunPipelineAudioLocation()._make_recorder_mock()
        write_audio = recorder.start.side_effect

        def start(path):
            seen.append(probe(path.parent))
            write_audio(path)

        recorder.start.side_effect = start
        processed: list[LockState] = []
        with (
            mock.patch("ownscribe.pipeline._create_recorder", return_value=recorder),
            mock.patch(
                "ownscribe.pipeline._do_transcribe_and_summarize",
                side_effect=lambda _config, _audio, out_dir: processed.append(probe(out_dir)),
            ),
        ):
            run_pipeline(config)

        [folder] = (tmp_path / "notes").iterdir()
        assert seen == processed == [LockState(busy=True, holder_pid=os.getpid())]
        assert probe(folder) == LockState(busy=False)

    def test_resume_refuses_a_folder_another_process_holds(self, tmp_path, hold_folder_lock):
        import pytest

        from ownscribe.locks import FolderBusyError
        from ownscribe.pipeline import run_resume

        (tmp_path / "transcript.md").write_text("# Transcript\n\n[00:00] Hello.\n")
        with (
            hold_folder_lock(tmp_path) as holder,
            mock.patch("ownscribe.pipeline.run_summarize") as summarize,
            pytest.raises(FolderBusyError) as refused,
        ):
            run_resume(Config(), str(tmp_path))

        assert refused.value.holder_pid == holder.pid
        summarize.assert_not_called()

    def test_resume_holds_the_lock_while_it_summarizes(self, tmp_path):
        from ownscribe.locks import LockState, probe
        from ownscribe.pipeline import run_resume

        (tmp_path / "transcript.md").write_text("# Transcript\n\n[00:00] Hello.\n")
        seen: list[LockState] = []
        with mock.patch(
            "ownscribe.pipeline.run_summarize", side_effect=lambda _config, path: seen.append(probe(tmp_path))
        ):
            run_resume(Config(), str(tmp_path))

        assert seen == [LockState(busy=True, holder_pid=os.getpid())]

    def test_summarize_refuses_a_folder_another_process_holds(self, tmp_path, hold_folder_lock):
        from ownscribe.locks import BUSY_EXIT_CODE, FolderBusyError
        from ownscribe.pipeline import run_summarize

        transcript = tmp_path / "transcript.md"
        transcript.write_text("# Transcript\n\n[00:00] Hello.\n")
        with (
            hold_folder_lock(tmp_path) as holder,
            mock.patch("ownscribe.pipeline.create_summarizer") as create,
            pytest.raises(FolderBusyError) as refused,
        ):
            run_summarize(Config(), str(transcript))

        assert refused.value.exit_code == BUSY_EXIT_CODE
        assert refused.value.holder_pid == holder.pid
        create.assert_not_called()
        assert sorted(p.name for p in tmp_path.iterdir()) == [".ownscribe.lock", "transcript.md"]

    def test_summarize_holds_the_lock_while_it_writes(self, tmp_path):
        from ownscribe.locks import LockState, probe
        from ownscribe.pipeline import run_summarize

        transcript = tmp_path / "transcript.md"
        transcript.write_text("# Transcript\n\n[00:00] Hello.\n")
        seen: list[LockState] = []
        summarizer = mock.MagicMock()
        summarizer.problem.return_value = None
        summarizer.summarize.side_effect = lambda _text, _instructions: seen.append(probe(tmp_path)) or "## Summary"
        summarizer.generate_title.return_value = ""
        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=summarizer),
            mock.patch("ownscribe.pipeline._needs_model_download", return_value=False),
            mock.patch("ownscribe.pipeline._download_summarization_model"),
        ):
            run_summarize(Config(), str(transcript))

        assert seen == [LockState(busy=True, holder_pid=os.getpid())]
        assert (tmp_path / "summary.md").is_file()

    def test_a_title_can_take_the_name_of_a_folder_holding_only_a_free_lock_file(self, tmp_path):
        from ownscribe.locks import LOCK_NAME
        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "260101-1200"
        source.mkdir()
        (source / "transcript.md").write_text("hi")
        leftover = tmp_path / "260101-budget-review"
        leftover.mkdir()
        (leftover / LOCK_NAME).write_text("{}")

        assert _rename_output_dir(source, "budget-review") == leftover
        assert (leftover / "transcript.md").read_text() == "hi"

    def test_a_folder_whose_lock_is_held_keeps_its_name(self, tmp_path, hold_folder_lock):
        from ownscribe.pipeline import _rename_output_dir

        source = tmp_path / "260101-1200"
        source.mkdir()
        claimed = tmp_path / "260101-budget-review"
        claimed.mkdir()

        with hold_folder_lock(claimed):
            renamed = _rename_output_dir(source, "budget-review")

        assert renamed == tmp_path / "260101-budget-review_1200"
        assert claimed.is_dir()


class TestResummarize:
    """resume --resummarize writes the summary again after speakers were moved."""

    @staticmethod
    def _folder(tmp_path, summary_name: str = "summary.md"):
        from ownscribe.meeting_meta import mark_summary_stale

        folder = tmp_path / "notes" / "260101-budget-review"
        folder.mkdir(parents=True)
        (folder / "transcript.md").write_text("# Transcript\n\n**Anna** [00:00]\nHello.\n")
        (folder / summary_name).write_text("old summary")
        mark_summary_stale(folder)
        return folder

    @staticmethod
    def _resummarize(folder, config: Config | None = None):
        from ownscribe.pipeline import run_resume

        summarizer = TestMeetingSavedEvent._summarizer(title="A Different Title")
        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=summarizer),
            mock.patch("ownscribe.pipeline._needs_model_download", return_value=False),
        ):
            run_resume(config or Config(), str(folder), resummarize=True)
        return summarizer

    def test_rewrites_the_summary_and_keeps_the_folder_name(self, tmp_path):
        from ownscribe.meeting_meta import summary_is_stale
        from ownscribe.output.markdown import format_summary

        folder = self._folder(tmp_path)

        summarizer = self._resummarize(folder)

        assert folder.is_dir()
        assert (folder / "summary.md").read_text() == format_summary("## Summary\nGood meeting.")
        assert not summary_is_stale(folder)
        summarizer.generate_title.assert_not_called()

    def test_keeps_the_existing_summary_format(self, tmp_path):
        folder = self._folder(tmp_path, summary_name="summary.json")

        self._resummarize(folder)  # output.format is markdown by default

        assert json.loads((folder / "summary.json").read_text()) == {"summary": "## Summary\nGood meeting."}
        assert not (folder / "summary.md").exists()

    def test_reports_the_same_folder_as_saved(self, tmp_path, capsys, monkeypatch):
        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        folder = self._folder(tmp_path)

        self._resummarize(folder)

        saved = [e for e in TestMeetingSavedEvent._events(capsys) if e["event"] == "meeting_saved"]
        assert saved == [{"ownscribe_progress": 1, "event": "meeting_saved", "folder": str(folder), "summary": "ok"}]

    def test_a_folder_without_a_transcript_fails(self, tmp_path, capsys):
        import pytest

        from ownscribe.pipeline import run_resume

        with pytest.raises(SystemExit):
            run_resume(Config(), str(tmp_path), resummarize=True)

        assert "No transcript" in capsys.readouterr().err

    def test_any_new_summary_clears_the_stale_mark(self, tmp_path):
        from ownscribe.meeting_meta import summary_is_stale
        from ownscribe.pipeline import run_summarize

        folder = self._folder(tmp_path)
        summarizer = TestMeetingSavedEvent._summarizer(title="")
        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=summarizer),
            mock.patch("ownscribe.pipeline._needs_model_download", return_value=False),
        ):
            run_summarize(Config(), str(folder / "transcript.md"))

        assert not summary_is_stale(folder)

    def test_the_cli_flag_reaches_resume(self, tmp_path):
        from click.testing import CliRunner

        from ownscribe.cli import cli

        with (
            mock.patch("ownscribe.cli.Config.load", return_value=Config()),
            mock.patch("ownscribe.pipeline.run_resume") as resume,
        ):
            result = CliRunner().invoke(cli, ["resume", str(tmp_path), "--resummarize"])

        assert result.exit_code == 0, result.output
        assert resume.call_args.kwargs == {"resummarize": True, "instructions": ""}

    def test_instructions_template_and_model_reach_the_summary(self, tmp_path):
        from click.testing import CliRunner

        from ownscribe.cli import cli

        with (
            mock.patch("ownscribe.cli.Config.load", return_value=Config()),
            mock.patch("ownscribe.pipeline.run_resume") as resume,
        ):
            result = CliRunner().invoke(
                cli,
                [
                    "resume",
                    str(tmp_path),
                    "--resummarize",
                    "--instructions",
                    "  Focus on the budget. ",
                    "--template",
                    "brief",
                    "--summary-model",
                    "gemma",
                ],
            )

        assert result.exit_code == 0, result.output
        config = resume.call_args.args[0]
        assert (config.summarization.template, config.summarization.model) == ("brief", "gemma")
        assert resume.call_args.kwargs == {"resummarize": True, "instructions": "Focus on the budget."}

    def test_instructions_and_model_need_resummarize(self, tmp_path):
        from click.testing import CliRunner

        from ownscribe.cli import cli

        for flag in ("--instructions", "--summary-model"):
            with (
                mock.patch("ownscribe.cli.Config.load", return_value=Config()),
                mock.patch("ownscribe.pipeline.run_resume") as resume,
            ):
                result = CliRunner().invoke(cli, ["resume", str(tmp_path), flag, "x"])
            assert result.exit_code == 2, flag
            assert "only with --resummarize" in result.output
            resume.assert_not_called()

    def test_records_what_the_summary_was_written_with(self, tmp_path):
        from ownscribe.meeting_meta import read_meta, summary_request
        from ownscribe.pipeline import run_resume

        folder = self._folder(tmp_path)
        config = Config()
        config.summarization.backend = "omlx"
        config.summarization.model = "gemma"
        summarizer = TestMeetingSavedEvent._summarizer()
        with (
            mock.patch("ownscribe.pipeline.create_summarizer", return_value=summarizer),
            mock.patch("ownscribe.pipeline._needs_model_download", return_value=False),
        ):
            run_resume(config, str(folder), resummarize=True, instructions="Write it in German.")

        summarizer.summarize.assert_called_once_with(mock.ANY, "Write it in German.")
        assert summary_request(folder, read_meta(folder)) == {
            "backend": "omlx",
            "model": "gemma",
            "template": "meeting",
            "instructions": "Write it in German.",
        }
