from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ownscribe.config import Config
    from ownscribe.summarization.base import Summarizer


_INSTALL_HINTS = {
    "openai": "uv add 'ownscribe[openai]'",
    "ollama": "uv add 'ownscribe[ollama]'",
}


#: Every backend name the config accepts. An unknown name used to fall through to
#: Ollama, so a typo like "opneai" quietly pointed at localhost and only surfaced
#: after the meeting had already been recorded.
KNOWN_BACKENDS = ("local", "ollama", "openai")


def create_summarizer(config: Config) -> Summarizer:
    """Create the appropriate summarizer based on config."""
    backend = config.summarization.backend
    if backend not in KNOWN_BACKENDS:
        raise ValueError(f"Unknown summarization backend {backend!r}. Expected one of: {', '.join(KNOWN_BACKENDS)}.")
    if backend == "local":
        from ownscribe.summarization.llama_cpp_summarizer import LlamaCppSummarizer

        return LlamaCppSummarizer(config.summarization, config.templates)
    try:
        if backend == "openai":
            from ownscribe.summarization.openai_summarizer import OpenAISummarizer

            return OpenAISummarizer(config.summarization, config.templates)
        from ownscribe.summarization.ollama_summarizer import OllamaSummarizer

        return OllamaSummarizer(config.summarization, config.templates)
    except ImportError as exc:
        hint = _INSTALL_HINTS.get(backend, f"uv add 'ownscribe[{backend}]'")
        raise ImportError(
            f"The '{backend}' summarization backend requires additional dependencies.\nInstall with: {hint}"
        ) from exc
