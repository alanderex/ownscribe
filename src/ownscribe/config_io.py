"""Machine-readable read/write access to ``config.toml``.

This backs the ``ownscribe config get`` / ``ownscribe config set`` commands and,
through them, the macOS menu-bar app's Settings pane. The dataclass hierarchy in
:mod:`ownscribe.config` stays the single source of truth for the schema; this
module only mirrors the *effective* config to JSON and writes individual values
back to disk while preserving the file's comments and formatting (via tomlkit).
"""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import tomlkit

from ownscribe.config import (
    AudioConfig,
    Config,
    DiarizationConfig,
    OutputConfig,
    SummarizationConfig,
    TranscriptionConfig,
    ensure_config_file,
)

# Editable sections exposed to `config set`, mapped to their dataclass so we can
# validate keys and coerce string input to the field's declared type. `templates`
# is intentionally excluded — custom templates are edited in the file directly.
_SECTIONS: dict[str, type] = {
    "audio": AudioConfig,
    "transcription": TranscriptionConfig,
    "diarization": DiarizationConfig,
    "summarization": SummarizationConfig,
    "output": OutputConfig,
}


def config_to_dict(config: Config) -> dict:
    """Serialize the effective config to a nested plain dict (JSON-ready).

    Includes env-var overrides already applied by :meth:`Config.load`. Computed
    properties such as ``OutputConfig.resolved_dir`` are not dataclass fields and
    are therefore omitted.
    """
    return dataclasses.asdict(config)


def config_to_json(config: Config) -> str:
    """Serialize the effective config as a pretty JSON string."""
    return json.dumps(config_to_dict(config), indent=2, ensure_ascii=False)


def _coerce(section: str, field: str, type_str: str, raw: str) -> bool | int | str:
    """Coerce a CLI string to the field's declared type, failing loudly on mismatch.

    With ``from __future__ import annotations`` in config.py, dataclass field
    types arrive as strings (e.g. ``"bool"``), so we dispatch on the name.
    """
    if type_str == "bool":
        low = raw.strip().lower()
        if low in ("true", "1", "yes", "on"):
            return True
        if low in ("false", "0", "no", "off"):
            return False
        raise ValueError(
            f"{section}.{field} expects a boolean (true/false), got {raw!r}"
        )
    if type_str == "int":
        try:
            return int(raw)
        except ValueError:
            raise ValueError(
                f"{section}.{field} expects an integer, got {raw!r}"
            ) from None
    # Everything else is a plain string.
    return raw


def _field_types(section_cls: type) -> dict[str, str]:
    """Map a section dataclass's field names to their annotation strings."""
    return {f.name: f.type for f in dataclasses.fields(section_cls)}


def set_config_value(key: str, value: str) -> Path:
    """Set ``section.field = value`` in config.toml, preserving comments.

    Creates the config file from the default template if it does not exist.
    Raises ``ValueError`` with an explicit message on an unknown section or key,
    or a value that cannot be coerced to the field's type. Returns the path
    written.
    """
    if "." not in key:
        raise ValueError(
            f"Key must be 'section.field' (e.g. summarization.backend), got {key!r}"
        )
    section, _, field = key.partition(".")

    if section not in _SECTIONS:
        valid = ", ".join(sorted(_SECTIONS))
        raise ValueError(f"Unknown config section {section!r}. Valid sections: {valid}")

    field_types = _field_types(_SECTIONS[section])
    if field not in field_types:
        valid = ", ".join(sorted(field_types))
        raise ValueError(
            f"Unknown key {field!r} in [{section}]. Valid keys: {valid}"
        )

    coerced = _coerce(section, field, field_types[field], value)

    # Ensure the file exists (created from the documented default template), then
    # edit it in place so the user's comments and layout survive.
    path = ensure_config_file()
    doc = tomlkit.parse(path.read_text())
    if section not in doc:
        doc[section] = tomlkit.table()
    doc[section][field] = coerced
    path.write_text(tomlkit.dumps(doc))
    return path
