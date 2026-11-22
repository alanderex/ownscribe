"""OpenAI-compatible API summarization (LM Studio, llama.cpp server, etc.)."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

import openai

from ownscribe.config import SummarizationConfig
from ownscribe.summarization.base import Summarizer, SummarizerUnavailable
from ownscribe.summarization.prompts import clean_response

if TYPE_CHECKING:
    from openai.types.chat import ChatCompletionMessageParam

#: Seconds. Generous enough for a slow local model, finite so a hung
#: server cannot block the pipeline indefinitely.
_HTTP_TIMEOUT = 600


class OpenAISummarizer(Summarizer):
    """Summarizes transcripts using an OpenAI-compatible API."""

    def __init__(self, config: SummarizationConfig, templates: dict | None = None) -> None:
        super().__init__(config, templates)
        base_url = config.resolved_host
        if not base_url.endswith("/v1"):
            base_url = base_url.rstrip("/") + "/v1"
        self._base_url = base_url
        self._label = "oMLX" if config.backend == "omlx" else "The OpenAI-compatible server"
        # Most local servers ignore the key; servers that require auth (e.g. oMLX)
        # read it from config.api_key or the OPENAI_API_KEY env var.
        api_key = config.api_key or "not-needed"
        # Without a timeout a wedged server hangs summarize and ask forever.
        self._client = openai.OpenAI(base_url=base_url, api_key=api_key, timeout=_HTTP_TIMEOUT)

    def chat(
        self,
        system_prompt: str,
        user_prompt: str,
        json_mode: bool = False,
        json_schema: dict | None = None,
    ) -> str:
        messages: list[ChatCompletionMessageParam] = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        formats_to_try: list[dict | None] = [None]
        if json_mode:
            if json_schema is not None:
                formats_to_try = [
                    {"type": "json_object"},
                    {"type": "json_schema", "json_schema": json_schema},
                    None,
                ]
            else:
                formats_to_try = [{"type": "json_object"}, None]
        for fmt in formats_to_try:
            try:
                kwargs: dict[str, Any] = {}
                if fmt is not None:
                    kwargs["response_format"] = fmt
                response = self._client.chat.completions.create(
                    model=self._config.model,
                    messages=messages,
                    **kwargs,
                )
                return clean_response(response.choices[0].message.content or "")
            except openai.BadRequestError:
                continue
        return ""

    @property
    def base_url(self) -> str:
        """The API address in use: the resolved host, ending in /v1."""
        return self._base_url

    def served_models(self) -> list[str]:
        """The ids of the models the server offers, sorted by name.

        Raises SummarizerUnavailable saying why the server could not be asked.
        """
        try:
            page = self._client.models.list()
        except openai.AuthenticationError:
            raise SummarizerUnavailable(
                f"{self._label} refused the API key (summarization.api_key or OPENAI_API_KEY)."
            ) from None
        except openai.APIConnectionError:
            raise SummarizerUnavailable(f"{self._label} is not reachable at {self._base_url}. Is it running?") from None
        except openai.APIError as exc:
            raise SummarizerUnavailable(f"{self._label} at {self._base_url} answered with an error: {exc}") from None
        return sorted((model.id for model in page), key=str.casefold)

    def problem(self) -> str | None:
        try:
            served = self.served_models()
        except SummarizerUnavailable as exc:
            return str(exc)
        # oMLX lists every model it has downloaded, loaded or not, so a model missing
        # from the list cannot be summarized with. Other servers may list only the
        # models they have loaded, so they are not held to their list.
        if self._config.backend == "omlx" and self._config.model not in served:
            return (
                f"oMLX does not serve the model '{self._config.model}' (summarization.model). "
                f"`ownscribe models --json` lists the {len(served)} it serves."
            )
        return None

    def is_available(self) -> bool:
        return self.problem() is None

    def _complete(self, system_prompt: str, user_prompt: str) -> str:
        response = self._client.chat.completions.create(
            model=self._config.model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        )
        return clean_response(response.choices[0].message.content or "")

    def generate_title(self, summary_text: str) -> str:
        from ownscribe.summarization.prompts import TITLE_PROMPT, TITLE_SYSTEM

        response = self._client.chat.completions.create(
            model=self._config.model,
            messages=[
                {"role": "system", "content": TITLE_SYSTEM},
                {"role": "user", "content": TITLE_PROMPT.format(summary=summary_text)},
            ],
        )
        return clean_response(response.choices[0].message.content or "").strip()
