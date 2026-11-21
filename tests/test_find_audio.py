"""Tests for media-file discovery in _find_audio (audio + video containers)."""

from __future__ import annotations

from ownscribe.config import Config
from ownscribe.pipeline import _find_audio, find_meeting_audio


def _touch(directory, *names):
    for name in names:
        (directory / name).write_bytes(b"")


class TestFindAudioVideo:
    def test_finds_mp4_when_no_recording_wav(self, tmp_path):
        _touch(tmp_path, "meeting.mp4")
        assert _find_audio(tmp_path) == tmp_path / "meeting.mp4"

    def test_finds_mov(self, tmp_path):
        _touch(tmp_path, "meeting.mov")
        assert _find_audio(tmp_path) == tmp_path / "meeting.mov"

    def test_finds_mkv(self, tmp_path):
        _touch(tmp_path, "meeting.mkv")
        assert _find_audio(tmp_path) == tmp_path / "meeting.mkv"

    def test_prefers_recording_wav_over_video(self, tmp_path):
        _touch(tmp_path, "meeting.mp4", "recording.wav")
        assert _find_audio(tmp_path) == tmp_path / "recording.wav"

    def test_case_insensitive_extension(self, tmp_path):
        _touch(tmp_path, "Meeting.MP4")
        assert _find_audio(tmp_path) == tmp_path / "Meeting.MP4"

    def test_ignores_unrelated_files(self, tmp_path):
        _touch(tmp_path, "notes.txt", "slides.pdf")
        assert _find_audio(tmp_path) is None


class TestFindAudioSkipsUnmergedTracks:
    """A crash mid-recording leaves the helper's per-source tracks unmerged."""

    def test_crash_leftovers_are_not_a_recording(self, tmp_path):
        _touch(tmp_path, "recording.wav.mic.tmp.wav", "recording.wav.sys.tmp.wav")
        assert _find_audio(tmp_path) is None

    def test_real_media_next_to_leftovers_is_found(self, tmp_path):
        _touch(tmp_path, "recording.wav.mic.tmp.wav", "recording.wav.sys.tmp.wav", "call.m4a")
        assert _find_audio(tmp_path) == tmp_path / "call.m4a"

    def test_merged_recording_still_wins(self, tmp_path):
        _touch(tmp_path, "recording.wav.mic.tmp.wav", "recording.wav")
        assert _find_audio(tmp_path) == tmp_path / "recording.wav"

    def test_suffix_check_ignores_case(self, tmp_path):
        _touch(tmp_path, "Recording.WAV.MIC.TMP.WAV")
        assert _find_audio(tmp_path) is None


class TestFindMeetingAudio:
    """Resolve a meeting folder's recording, including a separate output.audio_dir."""

    @staticmethod
    def _config(tmp_path, *, separate: bool) -> Config:
        config = Config()
        config.output.dir = str(tmp_path / "notes")
        config.output.audio_dir = str(tmp_path / "audio") if separate else ""
        return config

    def test_audio_in_the_meeting_folder(self, tmp_path):
        config = self._config(tmp_path, separate=False)
        meeting = tmp_path / "notes" / "260101-standup"
        meeting.mkdir(parents=True)
        _touch(meeting, "recording.wav")
        assert find_meeting_audio(config, meeting) == meeting / "recording.wav"

    def test_audio_in_the_separate_audio_dir(self, tmp_path):
        config = self._config(tmp_path, separate=True)
        meeting = tmp_path / "notes" / "260101-standup"
        audio = tmp_path / "audio" / "260101-standup"
        meeting.mkdir(parents=True)
        audio.mkdir(parents=True)
        _touch(audio, "recording.wav")
        assert find_meeting_audio(config, meeting) == audio / "recording.wav"

    def test_the_folders_own_file_wins(self, tmp_path):
        config = self._config(tmp_path, separate=True)
        meeting = tmp_path / "notes" / "260101-standup"
        audio = tmp_path / "audio" / "260101-standup"
        meeting.mkdir(parents=True)
        audio.mkdir(parents=True)
        _touch(meeting, "call.m4a")
        _touch(audio, "recording.wav")
        assert find_meeting_audio(config, meeting) == meeting / "call.m4a"

    def test_no_recording_kept(self, tmp_path):
        config = self._config(tmp_path, separate=True)
        meeting = tmp_path / "notes" / "260101-standup"
        meeting.mkdir(parents=True)
        _touch(meeting, "transcript.md")
        assert find_meeting_audio(config, meeting) is None
