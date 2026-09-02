"""Tests for progress parsing and TUI rendering helpers."""

from __future__ import annotations

import contextlib
import io
from unittest import mock

from ownscribe.progress import (
    _BRAILLE,
    DownloadProgressEvent,
    DownloadProgressWriter,
    PipelineProgress,
    download_event_fraction,
    format_download_progress,
    parse_download_progress,
)


class TestDownloadProgressParsing:
    def test_parses_tqdm_style_line(self):
        event = parse_download_progress("model.bin: 26%|##5       | 123MB/466MB [00:10<00:20, 12.3MB/s]")

        assert event is not None
        assert event.filename == "model.bin"
        assert event.percent == 26.0
        assert event.bytes_done is not None
        assert event.bytes_total is not None
        assert format_download_progress(event).startswith("model.bin")

    def test_ignores_non_progress_noise(self):
        assert parse_download_progress("Some unrelated log line") is None

    def test_writer_handles_partial_carriage_return_updates(self):
        events = []
        writer = DownloadProgressWriter(events.append)

        writer.write("model.bin: 12%|##")
        writer.write("         | 12MB/100MB [00:01<00:08, 10MB/s]\r")
        writer.flush()

        assert events
        assert events[-1].percent == 12.0
        assert events[-1].filename == "model.bin"

    def test_writer_ignores_unknown_size_units_without_crashing(self):
        events = []
        writer = DownloadProgressWriter(events.append)

        writer.write("model.bin: 10%|#         | 1EiB/2EiB [00:01<00:09]\r")
        writer.flush()

        assert events == []


class TestDownloadProgressFraction:
    def test_prefers_bytes_ratio(self):
        event = parse_download_progress("model.bin: 26%|##5| 123MB/466MB [00:10<00:20]")
        assert event is not None
        fraction = download_event_fraction(event)
        assert fraction is not None
        assert 0.26 < fraction < 0.27

    def test_uses_percent_when_bytes_missing(self):
        event = parse_download_progress("Progress 75% complete")
        assert event is not None
        assert download_event_fraction(event) == 0.75

    def test_clamps_fraction(self):
        from ownscribe.progress import DownloadProgressEvent

        assert download_event_fraction(DownloadProgressEvent(percent=150)) == 1.0
        assert download_event_fraction(DownloadProgressEvent(percent=-5)) == 0.0

    def test_returns_none_without_progress_numbers(self):
        assert download_event_fraction(DownloadProgressEvent(filename="model.bin")) is None


class TestDownloadProgressFormatting:
    def test_can_omit_percent_when_bar_already_shows_it(self):
        event = DownloadProgressEvent(
            filename="model.bin",
            percent=10.0,
            bytes_done=10 * 1024**2,
            bytes_total=100 * 1024**2,
        )
        text = format_download_progress(event, include_percent=False)

        assert "model.bin" in text
        assert "%" not in text


class TestPipelineProgressDetails:
    def test_renders_detail_line_for_active_step(self):
        progress = PipelineProgress(transcribe=False, include_prepare=True)
        progress._stderr = io.StringIO()
        progress.begin("preparing_models")
        progress.set_detail("preparing_models", "Downloading model.bin 12 MB / 100 MB (12%)")

        progress._render_all(final=True)
        output = progress._stderr.getvalue()

        assert "Preparing models" in output
        assert "Downloading model.bin" in output

        progress._stop.set()
        if progress._thread is not None:
            progress._thread.join()

    def test_detail_clears_on_complete(self):
        progress = PipelineProgress(transcribe=False, include_prepare=True)
        progress._stderr = io.StringIO()
        progress.begin("preparing_models")
        progress.set_detail("preparing_models", "Downloading...")
        progress.complete("preparing_models")

        progress._render_all(final=True)
        output = progress._stderr.getvalue()

        assert "Downloading..." not in output

        progress._stop.set()
        if progress._thread is not None:
            progress._thread.join()

    def test_determinate_active_row_includes_spinner_glyph(self):
        progress = PipelineProgress(transcribe=False, include_prepare=True)
        progress._stderr = io.StringIO()
        progress.begin("preparing_models")
        progress.update("preparing_models", 0.1)

        with mock.patch("ownscribe.progress.time.time", return_value=0.0):
            progress._render_all(final=False)

        output = progress._stderr.getvalue()
        assert f"  {_BRAILLE[0]} Preparing models" in output
        assert "[██" in output or "[█" in output

        progress._stop.set()
        if progress._thread is not None:
            progress._thread.join()

    def test_renderer_clears_each_line_and_stale_rows_when_detail_disappears(self):
        progress = PipelineProgress(transcribe=False, include_prepare=True)
        progress._stderr = io.StringIO()
        progress.begin("preparing_models")
        progress.set_detail("preparing_models", "Downloading...")

        progress._render_all(final=True)
        first = progress._stderr.getvalue()
        first_len = len(first)
        assert first.count("\033[K\n") >= 2

        progress.set_detail("preparing_models", None)
        progress._render_all(final=True)
        second_delta = progress._stderr.getvalue()[first_len:]

        assert "\033[2A" in second_delta
        # One real line + one blank clearing line for the removed detail row.
        assert second_delta.count("\033[K\n") == 2
        assert "Downloading..." not in second_delta

        progress._stop.set()
        if progress._thread is not None:
            progress._thread.join()

    def test_preparing_models_is_not_included_by_default(self):
        progress = PipelineProgress(transcribe=True)
        assert "preparing_models" not in progress._step_map

    def test_preparing_models_can_be_enabled_explicitly(self):
        progress = PipelineProgress(transcribe=False, include_prepare=True)
        assert "preparing_models" in progress._step_map


class TestProgressEvents:
    """NDJSON progress for GUI front-ends (OWNSCRIBE_PROGRESS_EVENTS=1).

    The ANSI checklist is unparseable by a subprocess caller, so the menu-bar app could
    only ever show an indeterminate spinner. These events are the machine-readable
    alternative; the default (unset) path must keep drawing the TUI exactly as before.
    """

    @staticmethod
    def _events(capsys) -> list[dict]:
        """Every well-formed event line written to stderr, in order."""
        import json

        out = []
        for line in capsys.readouterr().err.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue  # ordinary stderr (torch warnings) — not an event
            if isinstance(obj, dict) and "ownscribe_progress" in obj:
                out.append(obj)
        return out

    def test_disabled_by_default_emits_no_json(self, capsys, monkeypatch):
        from ownscribe.progress import PipelineProgress

        monkeypatch.delenv("OWNSCRIBE_PROGRESS_EVENTS", raising=False)
        with PipelineProgress(summarize=True) as p:
            p.begin("transcribing")
            p.update("transcribing", 0.5)
            p.complete("transcribing")

        assert self._events(capsys) == []

    def test_emits_the_step_list_up_front(self, capsys, monkeypatch):
        from ownscribe.progress import PipelineProgress

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        with PipelineProgress(summarize=True, diarize=True):
            pass

        first = self._events(capsys)[0]
        assert first["event"] == "steps"
        keys = [s["key"] for s in first["steps"]]
        assert "transcribing" in keys and "summarizing" in keys
        # sub-steps carry their nesting so a UI can indent without knowing the pipeline
        assert any(s["indent"] == 1 for s in first["steps"])

    def test_step_lifecycle(self, capsys, monkeypatch):
        from ownscribe.progress import PipelineProgress

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        with PipelineProgress() as p:
            p.begin("transcribing")
            p.set_detail("transcribing", "Decoding audio…")
            p.update("transcribing", 1.0)
            p.complete("transcribing")

        seen = [(e["event"], e.get("key")) for e in self._events(capsys)]
        assert ("begin", "transcribing") in seen
        assert ("detail", "transcribing") in seen
        assert ("progress", "transcribing") in seen
        assert ("complete", "transcribing") in seen
        assert seen[-1][0] == "done"

    def test_progress_is_throttled_but_keeps_the_endpoints(self, capsys, monkeypatch):
        from ownscribe.progress import PipelineProgress

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        with PipelineProgress() as p:
            p.begin("transcribing")
            for i in range(1000):
                p.update("transcribing", i / 999)

        fractions = [e["fraction"] for e in self._events(capsys) if e["event"] == "progress"]
        # 1000 updates must not become 1000 lines on the pipe...
        assert len(fractions) < 150
        # ...but the ends have to survive, or a bar never starts empty or fills.
        assert fractions[0] == 0.0
        assert fractions[-1] == 1.0

    def test_failure_is_reported_as_failure_not_success(self, capsys, monkeypatch):
        """The TUI marks in-flight steps 'done' on teardown even when raising."""
        from ownscribe.progress import PipelineProgress

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        with contextlib.suppress(RuntimeError), PipelineProgress() as p:
            p.begin("transcribing")
            raise RuntimeError("boom")

        events = self._events(capsys)
        assert ("failed", "transcribing") in [(e["event"], e.get("key")) for e in events]
        assert events[-1] == {"ownscribe_progress": 1, "event": "done", "ok": False}

    def test_explicit_fail_is_emitted(self, capsys, monkeypatch):
        from ownscribe.progress import PipelineProgress

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        with PipelineProgress(summarize=True) as p:
            p.begin("summarizing")
            p.fail("summarizing")

        assert ("failed", "summarizing") in [(e["event"], e.get("key")) for e in self._events(capsys)]

    def test_events_are_one_object_per_line(self, capsys, monkeypatch):
        """A consumer reads line-by-line; a multi-line object would break framing."""
        import json

        from ownscribe.progress import PipelineProgress

        monkeypatch.setenv("OWNSCRIBE_PROGRESS_EVENTS", "1")
        with PipelineProgress(diarize=True) as p:
            p.begin("transcribing")
            p.set_detail("transcribing", "multi\nline\tdetail")
            p.complete("transcribing")

        for line in capsys.readouterr().err.splitlines():
            json.loads(line)  # every line must parse standalone


class TestFailureRendering:
    """The drawing path must not report an interrupted step as done."""

    @staticmethod
    def _render(monkeypatch, body) -> str:
        from ownscribe.progress import PipelineProgress

        monkeypatch.delenv("OWNSCRIBE_PROGRESS_EVENTS", raising=False)
        stderr = io.StringIO()
        monkeypatch.setattr("sys.stderr", stderr)
        with contextlib.suppress(RuntimeError), PipelineProgress(summarize=True) as p:
            body(p)
        return stderr.getvalue()

    def test_interrupted_step_is_not_marked_done(self, monkeypatch):
        """It used to print "✔ Transcribing done." right before the traceback."""

        def body(p):
            p.begin("transcribing")
            raise RuntimeError("boom")

        out = self._render(monkeypatch, body)

        assert "Transcribing done." not in out
        assert "Transcribing failed." in out

    def test_explicit_failure_is_shown(self, monkeypatch):
        """fail() dropped the step from _active, so it rendered as an empty circle."""

        def body(p):
            p.begin("summarizing")
            p.fail("summarizing")

        out = self._render(monkeypatch, body)

        assert "Summarizing failed." in out

    def test_a_clean_run_still_reports_done(self, monkeypatch):
        def body(p):
            p.begin("transcribing")
            p.complete("transcribing")

        out = self._render(monkeypatch, body)

        assert "Transcribing done." in out
        assert "failed" not in out
