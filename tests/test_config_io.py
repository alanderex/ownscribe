"""Tests for machine-readable config get/set (backs the GUI Settings pane)."""

from __future__ import annotations

import json

import pytest

from ownscribe import config_io
from ownscribe.config import Config


@pytest.fixture
def temp_config(tmp_path, monkeypatch):
    """Point config.py's module-level paths at a temp dir for isolated writes."""
    cfg_dir = tmp_path / "ownscribe"
    cfg_path = cfg_dir / "config.toml"
    monkeypatch.setattr("ownscribe.config.CONFIG_DIR", cfg_dir)
    monkeypatch.setattr("ownscribe.config.CONFIG_PATH", cfg_path)
    return cfg_path


class TestConfigToDict:
    def test_includes_all_sections(self):
        d = config_io.config_to_dict(Config())
        assert {"audio", "transcription", "diarization", "summarization", "output", "templates"} <= set(d)

    def test_reflects_values(self):
        cfg = Config()
        cfg.summarization.backend = "openai"
        assert config_io.config_to_dict(cfg)["summarization"]["backend"] == "openai"

    def test_omits_computed_properties(self):
        # resolved_dir is a property, not a dataclass field.
        assert "resolved_dir" not in config_io.config_to_dict(Config())["output"]

    def test_json_is_valid(self):
        json.loads(config_io.config_to_json(Config()))


class TestSetConfigValue:
    def test_creates_file_and_sets_string(self, temp_config):
        path = config_io.set_config_value("summarization.backend", "openai")
        assert path == temp_config
        assert 'backend = "openai"' in temp_config.read_text()

    def test_coerces_bool(self, temp_config):
        config_io.set_config_value("summarization.enabled", "false")
        assert "enabled = false" in temp_config.read_text()

    def test_coerces_int(self, temp_config):
        config_io.set_config_value("diarization.max_speakers", "3")
        assert "max_speakers = 3" in temp_config.read_text()

    def test_preserves_comments(self, temp_config):
        config_io.set_config_value("transcription.model", "large-v3")
        assert "# empty = auto-detect" in temp_config.read_text()

    def test_updates_existing_key_in_place(self, temp_config):
        # Repeated sets must update the existing key, not append duplicates.
        config_io.set_config_value("summarization.enabled", "false")
        before = temp_config.read_text().count("enabled =")
        config_io.set_config_value("summarization.enabled", "true")
        after = temp_config.read_text().count("enabled =")
        assert before == after

    def test_unknown_section(self, temp_config):
        with pytest.raises(ValueError, match="Unknown config section"):
            config_io.set_config_value("nope.x", "1")

    def test_unknown_key(self, temp_config):
        with pytest.raises(ValueError, match="Unknown key"):
            config_io.set_config_value("audio.bogus", "1")

    def test_bad_bool(self, temp_config):
        with pytest.raises(ValueError, match="boolean"):
            config_io.set_config_value("summarization.enabled", "maybe")

    def test_bad_int(self, temp_config):
        with pytest.raises(ValueError, match="integer"):
            config_io.set_config_value("diarization.max_speakers", "lots")

    def test_missing_dot(self, temp_config):
        with pytest.raises(ValueError, match=r"section\.field"):
            config_io.set_config_value("backend", "openai")

    def test_roundtrip_via_load(self, temp_config):
        config_io.set_config_value("summarization.model", "mlx-community--gemma")
        assert Config.load().summarization.model == "mlx-community--gemma"
