"""Tests for the Core Audio helper command line."""

from __future__ import annotations

from pathlib import Path
from unittest import mock


def _make_recorder(**kwargs):
    from ownscribe.audio.coreaudio import CoreAudioRecorder

    binary = Path("/usr/local/bin/ownscribe-audio")
    with mock.patch("ownscribe.audio.coreaudio._find_binary", return_value=binary):
        return CoreAudioRecorder(**kwargs)


def _capture_cmd(recorder, tmp_path: Path) -> list[str]:
    with mock.patch("ownscribe.audio.coreaudio.subprocess.Popen") as mock_popen:
        recorder.start(tmp_path / "recording.wav")
    return mock_popen.call_args[0][0]


class TestDownloadBinaryArchitecture:
    """Releases only publish ownscribe-audio-arm64; anything else must say so."""

    @staticmethod
    def _download(platform_name: str, machine: str, capsys):
        from ownscribe.audio import coreaudio

        with (
            mock.patch.object(coreaudio.sys, "platform", platform_name),
            mock.patch.object(coreaudio.platform, "machine", return_value=machine),
            mock.patch.object(coreaudio.urllib.request, "urlretrieve") as urlretrieve,
        ):
            result = coreaudio._download_binary()
        return result, urlretrieve, capsys.readouterr()

    def test_intel_mac_explains_instead_of_downloading(self, capsys):
        result, urlretrieve, captured = self._download("darwin", "x86_64", capsys)

        assert result is None
        # A download would 404; the failure used to be swallowed silently.
        urlretrieve.assert_not_called()
        assert "Apple Silicon" in captured.err
        assert "x86_64" in captured.err

    def test_non_macos_stays_quiet(self, capsys):
        result, urlretrieve, captured = self._download("linux", "x86_64", capsys)

        assert result is None
        urlretrieve.assert_not_called()
        assert captured.err == ""

    def test_apple_silicon_still_downloads(self, tmp_path):
        from ownscribe.audio import coreaudio

        with (
            mock.patch.object(coreaudio.sys, "platform", "darwin"),
            mock.patch.object(coreaudio.platform, "machine", return_value="arm64"),
            mock.patch.object(coreaudio, "_CACHE_DIR", tmp_path),
            mock.patch.object(coreaudio.urllib.request, "urlretrieve") as urlretrieve,
            mock.patch.object(Path, "chmod"),
        ):
            result = coreaudio._download_binary()

        assert result == tmp_path / "ownscribe-audio"
        assert "ownscribe-audio-arm64" in urlretrieve.call_args[0][0]


class TestCoreAudioRecorderCommand:
    def test_mic_and_device_passed_when_mic_enabled(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(mic=True, mic_device="USB Mic"), tmp_path)

        assert "--mic" in cmd
        assert cmd[cmd.index("--mic-device") + 1] == "USB Mic"

    def test_mic_device_ignored_when_mic_disabled(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(mic=False, mic_device="USB Mic"), tmp_path)

        assert "--mic" not in cmd
        assert "--mic-device" not in cmd

    def test_capture_mode_all(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(capture_mode="all"), tmp_path)

        assert "--capture-mode-all" in cmd

    def test_capture_mode_picker(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(capture_mode="picker"), tmp_path)

        assert "--capture-mode-all" not in cmd

    def test_silence_timeout_passed(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(silence_timeout=120), tmp_path)

        assert cmd[cmd.index("--silence-timeout") + 1] == "120"

    def test_silence_timeout_omitted_when_disabled(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(silence_timeout=0), tmp_path)

        assert "--silence-timeout" not in cmd


def _stop_with_stderr(stderr_text: str, capsys):
    """Run stop() against a finished fake helper and return what reached the user."""
    recorder = _make_recorder()
    process = mock.Mock()
    process.poll.return_value = 0  # already exited: skip the signal/wait dance
    process.stderr.read.return_value = stderr_text.encode()
    recorder._process = process

    recorder.stop()
    return capsys.readouterr().err, recorder


class TestHelperStderrFiltering:
    """The helper's stderr is scraped for status; routine chatter must not look like errors.

    Upstream f2383c0 renamed the Swift marker `[MIC_RECONFIG]` to `Mic reconfigure:` but
    left _NOISE_PREFIXES untouched, so every recording during which the audio route changed
    ended by printing a reconfigure notice through the error path.
    """

    def test_routine_lines_are_filtered(self, capsys):
        err, _ = _stop_with_stderr(
            "Recording system audio to /tmp/a.wav... Press Ctrl+C to stop.\n"
            "Recording microphone audio to /tmp/a.mic.tmp.wav...\n"
            "[MIC_MUTED]\n"
            "[MIC_UNMUTED]\n"
            "Saved /tmp/a.wav (1.2 MB)\n"
            "Merged audio saved to /tmp/a.wav\n",
            capsys,
        )

        assert err == ""

    def test_route_change_notice_is_not_reported_as_an_error(self, capsys):
        err, _ = _stop_with_stderr("Mic reconfigure: audio route changed; rebinding microphone input.\n", capsys)

        assert err == ""

    def test_reconfigure_failures_stay_visible(self, capsys):
        """The three failure variants mean the mic degraded or stopped — never filter these."""
        for line in (
            "Mic reconfigure: Error Domain=NSOSStatusErrorDomain — falling back to default input.",
            "Mic reconfigure: input did not return after 20 retries; mic stopped.",
            "Mic reconfigure: failed to restart engine: some error",
        ):
            err, _ = _stop_with_stderr(line + "\n", capsys)

            assert line in err, f"filtered a real failure: {line}"

    def test_silence_warning_is_detected_and_surfaced(self, capsys):
        err, recorder = _stop_with_stderr(
            "[SILENCE_WARNING] Recording appears silent. Check Screen Recording permission.\n",
            capsys,
        )

        assert recorder.silence_warning is True
        assert "Screen Recording" in err

    def test_silence_timeout_sets_flag_without_printing(self, capsys):
        err, recorder = _stop_with_stderr("[SILENCE_TIMEOUT]\n", capsys)

        assert recorder.silence_timed_out is True
        assert err == ""

    def test_unknown_errors_still_reach_the_user(self, capsys):
        err, _ = _stop_with_stderr("Stream error: something went wrong\n", capsys)

        assert "Stream error: something went wrong" in err
