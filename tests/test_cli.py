"""Tests for CLI command parsing."""

from __future__ import annotations

from unittest import mock

from click.testing import CliRunner

from ownscribe.cli import cli
from ownscribe.config import Config


def _mock_config(config: Config | None = None):
    """Return a mock that makes Config.load() return a default Config."""
    return mock.patch("ownscribe.cli.Config.load", return_value=config or Config())


class TestMainCommand:
    def test_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["--help"])
        assert result.exit_code == 0
        assert "Fully local meeting transcription and summarization" in result.output

    def test_no_summarize_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--no-summarize"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.summarization.enabled is False

    def test_mic_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--mic"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.audio.mic is True

    def test_no_mic_flag_forces_system_only(self):
        cfg = Config()
        cfg.audio.mic = True  # default says mic on
        runner = CliRunner()
        with _mock_config(cfg), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--no-mic"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.audio.mic is False

    def test_mic_unset_keeps_config_default(self):
        cfg = Config()
        cfg.audio.mic = True
        runner = CliRunner()
        with _mock_config(cfg), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, [])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.audio.mic is True

    def test_device_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--device", "USB Mic"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.audio.device == "USB Mic"
            assert config.audio.backend == "sounddevice"

    def test_model_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--model", "large-v3"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.transcription.model == "large-v3"

    def test_language_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--language", "de"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.transcription.language == "de"

    def test_empty_language_forces_auto_detect(self):
        cfg = Config()
        cfg.transcription.language = "de"  # configured default
        runner = CliRunner()
        with _mock_config(cfg), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--language", ""])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.transcription.language == ""  # cleared, not "de"

    def test_silence_timeout_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--silence-timeout", "60"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.audio.silence_timeout == 60

    def test_silence_timeout_disable(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--silence-timeout", "0"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.audio.silence_timeout == 0


class TestSubcommandHelp:
    def test_transcribe_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["transcribe", "--help"])
        assert result.exit_code == 0
        assert "Transcribe an audio file" in result.output

    def test_summarize_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["summarize", "--help"])
        assert result.exit_code == 0
        assert "Summarize a transcript file" in result.output

    def test_devices_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["devices", "--help"])
        assert result.exit_code == 0
        assert "List available audio input devices" in result.output

    def test_config_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["config", "--help"])
        assert result.exit_code == 0
        assert "Open the configuration file" in result.output

    def test_resume_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["resume", "--help"])
        assert result.exit_code == 0
        assert "Resume a partially-completed pipeline" in result.output

    def test_warmup_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["warmup", "--help"])
        assert result.exit_code == 0
        assert "Prefetch WhisperX/pyannote models" in result.output

    def test_cleanup_help(self):
        runner = CliRunner()
        result = runner.invoke(cli, ["cleanup", "--help"])
        assert result.exit_code == 0
        assert "Remove ownscribe data from disk" in result.output


class TestKeepRecordingFlag:
    def test_keep_recording_flag(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--no-keep-recording"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.output.keep_recording is False

    def test_keep_recording_default_is_true(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, [])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.output.keep_recording is True


class TestWarmupCommand:
    def test_warmup_invokes_pipeline_with_overrides(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_warmup") as mock_warmup:
            result = runner.invoke(cli, ["warmup", "--model", "large-v3", "--language", "de", "--with-diarization"])

        assert result.exit_code == 0
        config = mock_warmup.call_args[0][0]
        assert config.transcription.model == "large-v3"
        assert config.transcription.language == "de"
        assert config.diarization.enabled is True


class TestSpeakersFlag:
    def test_speakers_on_record(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline") as mock_run:
            result = runner.invoke(cli, ["--speakers", "3"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.diarization.min_speakers == 3
            assert config.diarization.max_speakers == 3

    def test_speakers_on_transcribe(self, tmp_path):
        audio = tmp_path / "a.wav"
        audio.write_bytes(b"RIFF")
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_transcribe") as mock_run:
            result = runner.invoke(cli, ["transcribe", str(audio), "--speakers", "2"])
            assert result.exit_code == 0
            config = mock_run.call_args[0][0]
            assert config.diarization.min_speakers == 2
            assert config.diarization.max_speakers == 2

    def test_speakers_rejects_zero(self):
        runner = CliRunner()
        with _mock_config(), mock.patch("ownscribe.pipeline.run_pipeline"):
            result = runner.invoke(cli, ["--speakers", "0"])
            assert result.exit_code != 0


class TestConfigGetSet:
    def test_config_get_outputs_json(self):
        runner = CliRunner()
        with _mock_config():
            result = runner.invoke(cli, ["config", "get"])
        assert result.exit_code == 0
        data = __import__("json").loads(result.output)
        assert "summarization" in data
        assert "audio" in data

    def test_config_get_redacts_secrets(self):
        cfg = Config()
        cfg.summarization.api_key = "sk-secret"
        cfg.diarization.hf_token = "hf-secret"
        runner = CliRunner()
        with _mock_config(cfg):
            result = runner.invoke(cli, ["config", "get"])
        assert result.exit_code == 0
        assert "sk-secret" not in result.output
        assert "hf-secret" not in result.output

    def test_config_get_reveal_secrets(self):
        cfg = Config()
        cfg.summarization.api_key = "sk-secret"
        runner = CliRunner()
        with _mock_config(cfg):
            result = runner.invoke(cli, ["config", "get", "--reveal-secrets"])
        assert result.exit_code == 0
        assert "sk-secret" in result.output

    def test_config_set_calls_io(self):
        runner = CliRunner()
        with (
            _mock_config(),
            mock.patch("ownscribe.config_io.set_config_value", return_value="/x/config.toml") as m,
        ):
            result = runner.invoke(cli, ["config", "set", "summarization.backend", "openai"])
        assert result.exit_code == 0
        m.assert_called_once_with("summarization.backend", "openai")
        assert "Set summarization.backend" in result.output

    def test_config_set_error_exits_nonzero(self):
        runner = CliRunner()
        with (
            _mock_config(),
            mock.patch("ownscribe.config_io.set_config_value", side_effect=ValueError("bad key")),
        ):
            result = runner.invoke(cli, ["config", "set", "x", "y"])
        assert result.exit_code == 1
        assert "bad key" in result.output

    def test_config_no_subcommand_opens_editor(self):
        from pathlib import Path

        runner = CliRunner()
        with (
            _mock_config(),
            mock.patch("ownscribe.cli.ensure_config_file", return_value=Path("/x/config.toml")),
            mock.patch("subprocess.run") as mrun,
        ):
            result = runner.invoke(cli, ["config"])
        assert result.exit_code == 0
        mrun.assert_called_once()


class TestSpeakerCommands:
    def test_list_speakers(self, tmp_path):
        p = tmp_path / "transcript.md"
        p.write_text("**SPEAKER_00** [00:00]\nHi\n\n**SPEAKER_01** [00:05]\nYo\n")
        runner = CliRunner()
        with _mock_config():
            result = runner.invoke(cli, ["list-speakers", str(p)])
        assert result.exit_code == 0
        assert __import__("json").loads(result.output) == ["SPEAKER_00", "SPEAKER_01"]

    def test_rename_speakers(self, tmp_path):
        p = tmp_path / "transcript.md"
        p.write_text("**SPEAKER_00** [00:00]\nHi\n")
        runner = CliRunner()
        with _mock_config():
            result = runner.invoke(cli, ["rename-speakers", str(p), "--map", "SPEAKER_00=Anna"])
        assert result.exit_code == 0
        assert "**Anna**" in p.read_text()
        assert "Renamed 1" in result.output

    def test_rename_speakers_bad_map(self, tmp_path):
        p = tmp_path / "transcript.md"
        p.write_text("**SPEAKER_00** [00:00]\nHi\n")
        runner = CliRunner()
        with _mock_config():
            result = runner.invoke(cli, ["rename-speakers", str(p), "--map", "oops"])
        assert result.exit_code != 0
        assert "LABEL=Name" in result.output

    def test_rename_speakers_requires_map(self, tmp_path):
        p = tmp_path / "transcript.md"
        p.write_text("**SPEAKER_00** [00:00]\nHi\n")
        runner = CliRunner()
        with _mock_config():
            result = runner.invoke(cli, ["rename-speakers", str(p)])
        assert result.exit_code != 0


class TestCleanup:
    def test_all_yes_removes_dirs(self, tmp_path):
        config_dir = tmp_path / "config"
        cache_dir = tmp_path / "cache"
        output_dir = tmp_path / "output"
        for d in (config_dir, cache_dir, output_dir):
            d.mkdir()
            (d / "file.txt").write_text("data")

        cfg = Config()
        cfg.output.dir = str(output_dir)

        runner = CliRunner()
        with (
            _mock_config(cfg),
            mock.patch("ownscribe.cli._CONFIG_DIR", str(config_dir)),
            mock.patch("ownscribe.cli._CACHE_DIR", str(cache_dir)),
        ):
            result = runner.invoke(cli, ["cleanup", "--all", "--yes"])

        assert result.exit_code == 0
        assert not config_dir.exists()
        assert not cache_dir.exists()
        assert not output_dir.exists()
        assert "Removed Config" in result.output
        assert "Removed Cache" in result.output
        assert "Removed Output" in result.output

    def test_config_only(self, tmp_path):
        config_dir = tmp_path / "config"
        cache_dir = tmp_path / "cache"
        output_dir = tmp_path / "output"
        config_dir.mkdir()
        cache_dir.mkdir()
        output_dir.mkdir()

        cfg = Config()
        cfg.output.dir = str(output_dir)

        runner = CliRunner()
        with (
            _mock_config(cfg),
            mock.patch("ownscribe.cli._CONFIG_DIR", str(config_dir)),
            mock.patch("ownscribe.cli._CACHE_DIR", str(cache_dir)),
        ):
            result = runner.invoke(cli, ["cleanup", "--config", "--yes"])

        assert result.exit_code == 0
        assert not config_dir.exists()
        assert cache_dir.exists()
        assert output_dir.exists()

    def test_skips_missing_dirs(self, tmp_path):
        cfg = Config()
        cfg.output.dir = str(tmp_path / "nonexistent")

        runner = CliRunner()
        with (
            _mock_config(cfg),
            mock.patch("ownscribe.cli._CONFIG_DIR", str(tmp_path / "no-config")),
            mock.patch("ownscribe.cli._CACHE_DIR", str(tmp_path / "no-cache")),
        ):
            result = runner.invoke(cli, ["cleanup", "--all", "--yes"])

        assert result.exit_code == 0
        assert "not found, skipping" in result.output
