# Ownscribe: transcription improvement plan (Phase 4)

Status: 2026-11-22, proposal. Phase 4 of `docs/ui-redesign-plan.md` (v2.3). Nothing here is built
until the evaluation below has run and the owner has approved the result.

## Goal

Faster transcription on the Apple GPU, better German and English (and mixed) recognition, better
handling of names and jargon, and fewer speaker corrections in the speaker editor. Everything stays
on the Mac; the only server is oMLX on `127.0.0.1`.

## Current state (verified in code, 2026-11-22)

- `WhisperXTranscriber` (`src/ownscribe/transcription/whisperx_transcriber.py`): faster-whisper
  through CTranslate2 on the CPU with int8 (`device = "cpu"`, `compute_type = "int8"`); the GPU is
  not used for speech recognition. Thread count from `transcription.threads` (0 = all cores).
- wav2vec2 alignment runs only when word timings are needed (diarization or JSON output).
- Diarization: pyannote with `diarization.device = "auto"` (MPS on Apple Silicon), then word-level
  speaker assignment.
- Vocabulary: `transcription.initial_prompt` and `transcription.hotwords` reach the Whisper decoder.
- The owner's config asks for `model = "large-v3-turbo"` and sets `transcription.backend = "mlx"`,
  a key this CLI does not know: it is ignored with a warning, so the run uses WhisperX on the CPU.
- oMLX 0.8.2 (`app.omlx`) runs on `127.0.0.1:8000` with several chat models and no speech model
  downloaded yet.

## What oMLX offers (read from the installed 0.8.2 bundle)

- `POST /v1/audio/transcriptions`, OpenAI-compatible, served through mlx-audio on the GPU. Form
  fields: `model`, `language`, `prompt`, `response_format`, `temperature`, `stream`, `max_tokens`,
  `word_timestamps`, `chunking_strategy`.
- `prompt` is passed to Qwen3-ASR as context injection (strong biasing) and to Whisper as an initial
  prompt (soft, about 224 tokens).
- `word_timestamps=true` (an oMLX extension) adds per-word `{word, start, end, probability}` for
  Whisper models.
- `response_format=diarized_json` returns speaker turns from backends that diarize (VibeVoice-ASR,
  Nemotron with its CTC head); not with streaming.
- `max_tokens` raises the output cap; VibeVoice-ASR's default of 8192 tokens stops after about
  24 minutes of audio.

## Candidate models

| Model | Strengths | Limits to check |
|---|---|---|
| Whisper large-v3-turbo (MLX) | The model the owner already chose, now on the GPU; word timestamps for pyannote | Same accuracy as today, only faster |
| Qwen3-ASR 1.7B / 0.6B | Open weights; German among its languages; trained context biasing through the prompt | Word timings for pyannote; long-audio behaviour |
| Parakeet-TDT-0.6B-v3 | 25 European languages incl. German, punctuation, word timestamps, very fast (`parakeet-mlx`) | Whether oMLX serves it; otherwise in-process `parakeet-mlx` |
| VibeVoice-ASR (MIT) | Recognition, diarization and timestamps in one pass, up to about 60 minutes | High memory (30 to 60 GB reported), a 59-minute cap per pass, language list unclear (model card: en, zh) |
| Voxtral | Served by oMLX (realtime backend) | Batch quality on meetings |

Sources: [NVIDIA Parakeet-TDT-0.6B model card](https://build.nvidia.com/nvidia/parakeet-tdt-0_6b/modelcard),
[parakeet-mlx](https://pypi.org/project/parakeet-mlx/),
[Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR),
[Qwen3-ASR technical report](https://arxiv.org/html/2601.21337),
[VibeVoice-ASR model card](https://huggingface.co/microsoft/VibeVoice-ASR/blob/main/README.md),
[VibeVoice-ASR on a Mac (Simon Willison)](https://simonwillison.net/2026/Apr/27/vibevoice/).

## Proposed design

- `transcription.backend = "whisperx" | "omlx"` becomes a real key; an unknown value fails with a
  message (today it is ignored). `whisperx` stays the default.
- `omlx` backend: a transcriber that posts the recording to `/v1/audio/transcriptions` with the
  configured model, `language`, and `prompt` built from `initial_prompt` and `hotwords`. Whisper
  models get `word_timestamps=true`. The response's segments and words map into `TranscriptResult`.
- Diarization: local pyannote plus word assignment, as today, for models that return word timings.
  For a model that diarizes itself, `response_format=diarized_json` replaces pyannote, but only if
  the evaluation shows it needs fewer corrections.
- Long recordings: split at silences with overlap when a model has a length cap. Matching speakers
  across chunks is only needed for self-diarizing models; with pyannote the whole file is diarized
  once.
- oMLX not running, or the model not downloaded: the run fails with a message naming the server and
  the model. No silent fallback to WhisperX.
- App: Settings gains the transcription backend and an oMLX model picker (models from `/v1/models`).

## Evaluation before building

1. The owner picks 4 recordings: German, English, mixed, and one over an hour.
2. Download the candidate speech models into oMLX (sizes listed first; downloads only with the
   owner's OK).
3. Run today's WhisperX configuration and 3 to 4 oMLX models on each recording. Measure wall time and
   peak memory.
4. Accuracy: the owner corrects a 2-minute excerpt of each recording by hand; word error rate per
   model on those excerpts.
5. Speakers: corrections needed in the speaker editor (Phase 2) per model and diarization path.
6. Write the results into this document and decide the default model and the diarization path.

## Risks

- Memory: a large chat model for summaries and a speech model loaded together in oMLX; the
  evaluation measures peak memory with both.
- GPU contention with recording (ScreenCaptureKit) when processing runs during a recording; Phase 5's
  capture-gap gate covers this.
- oMLX's API is young; the transcriber checks the response shape and fails clearly on surprises.
