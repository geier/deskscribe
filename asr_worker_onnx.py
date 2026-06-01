#!/usr/bin/env python3
import argparse
import json
import logging
import os
import re
import tempfile
import threading
from contextlib import asynccontextmanager
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, NamedTuple

from fastapi import FastAPI, File, Form, HTTPException, UploadFile


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8766
DEFAULT_MODEL_DIR = "models/parakeet-primeline-onnx"
DEFAULT_MODEL_NAME = "nemo-parakeet-tdt-0.6b-v3"
DEFAULT_PROVIDER = "CPUExecutionProvider"
LOGGER = logging.getLogger("asr_worker_onnx")
TOKEN_RE = re.compile(r"\w+|[^\w\s]+|\s+", re.UNICODE)
NUMBER_WORDS = {
    "zero": "0",
    "one": "1",
    "two": "2",
    "three": "3",
    "four": "4",
    "five": "5",
    "six": "6",
    "seven": "7",
    "eight": "8",
    "nine": "9",
    "ten": "10",
}
REQUIRED_MODEL_FILES = [
    "encoder-model.onnx",
    "decoder_joint-model.onnx",
    "vocab.txt",
    "config.json",
    "MODEL_LICENSE.md",
]


class Hotword(NamedTuple):
    spoken: str
    replacement: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a local ONNX ASR worker for DeskScribe.")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Bind host. Default: {DEFAULT_HOST}")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Bind port. Default: {DEFAULT_PORT}")
    parser.add_argument(
        "--model-dir",
        default=os.getenv("DESKSCRIBE_ONNX_MODEL_DIR", DEFAULT_MODEL_DIR),
        help=f"Directory containing exported ONNX artifacts. Default: {DEFAULT_MODEL_DIR}",
    )
    parser.add_argument(
        "--model-name",
        default=DEFAULT_MODEL_NAME,
        help=f"onnx-asr model type/name. Default: {DEFAULT_MODEL_NAME}",
    )
    parser.add_argument(
        "--provider",
        default=os.getenv("DESKSCRIBE_ONNX_PROVIDER", DEFAULT_PROVIDER),
        help=f"ONNX Runtime execution provider. Default: {DEFAULT_PROVIDER}",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable worker request/lifecycle logs.",
    )
    return parser.parse_args()


def create_app(model_dir: Path, model_name: str, provider: str) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        LOGGER.info("loading ONNX model name=%s dir=%s provider=%s", model_name, model_dir, provider)
        validate_model_dir(model_dir)

        import onnx_asr

        app.state.model = onnx_asr.load_model(model_name, path=str(model_dir), providers=[provider])
        app.state.transcribe_lock = threading.Lock()
        app.state.model_dir = str(model_dir)
        app.state.model_name = model_name
        app.state.provider = provider
        LOGGER.info("ONNX model loaded")
        yield

    app = FastAPI(title="DeskScribe ONNX ASR Worker", lifespan=lifespan)

    @app.get("/health")
    def health() -> dict[str, Any]:
        LOGGER.info("health check")
        return {
            "status": "ready",
            "runtime": "onnx",
            "model": app.state.model_name,
            "model_dir": app.state.model_dir,
            "provider": app.state.provider,
        }

    @app.post("/transcribe")
    async def transcribe(file: UploadFile = File(...), vocabulary: str | None = Form(None)) -> dict[str, str]:
        LOGGER.info("transcribe request filename=%s content_type=%s", file.filename, file.content_type)
        model = getattr(app.state, "model", None)
        if model is None:
            raise HTTPException(status_code=503, detail="ASR model is not loaded")
        hotwords = parse_vocabulary(vocabulary)

        suffix = Path(file.filename or "").suffix or ".wav"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
            audio_path = Path(handle.name)
            while chunk := await file.read(1024 * 1024):
                handle.write(chunk)

        try:
            try:
                lock = app.state.transcribe_lock
                with lock:
                    result = model.recognize(audio_path)
                text = extract_text(result)
                text = apply_hotwords(text, hotwords)
            except Exception as exc:
                LOGGER.exception("transcribe failed")
                raise HTTPException(status_code=422, detail=f"Transcription failed: {exc}") from exc
            LOGGER.info("transcribe complete characters=%s", len(text))
            return {"text": text}
        finally:
            await file.close()
            try:
                os.unlink(audio_path)
            except FileNotFoundError:
                pass

    return app


def validate_model_dir(model_dir: Path) -> None:
    missing = [name for name in REQUIRED_MODEL_FILES if not (model_dir / name).exists()]
    if missing:
        raise RuntimeError(
            "ONNX model export is incomplete at "
            f"{model_dir}. Missing: {', '.join(missing)}. "
            "Run scripts/export_nemo_onnx.py first."
        )


def extract_text(result: Any) -> str:
    if isinstance(result, str):
        return result
    if hasattr(result, "text"):
        return str(result.text)
    return str(result)


def parse_vocabulary(value: str | None) -> list[Hotword]:
    if not value:
        return []

    try:
        parsed = json.loads(value)
        if isinstance(parsed, list):
            candidates = [item for item in parsed if isinstance(item, str)]
        else:
            candidates = []
    except json.JSONDecodeError:
        candidates = value.splitlines()

    seen: set[tuple[str, str]] = set()
    words: list[Hotword] = []
    for candidate in candidates:
        word = candidate.strip()
        if not word:
            continue

        spoken, replacement = parse_hotword_entry(word)
        spoken_key = normalize_hotword(spoken)
        replacement_key = normalize_hotword(replacement)
        key = (spoken_key, replacement_key)
        if spoken_key and replacement_key and key not in seen:
            seen.add(key)
            words.append(Hotword(spoken=spoken, replacement=replacement))
    return words


def parse_hotword_entry(value: str) -> tuple[str, str]:
    for separator in ("=>", "->"):
        if separator in value:
            spoken, replacement = value.split(separator, 1)
            spoken = spoken.strip()
            replacement = replacement.strip()
            if spoken and replacement:
                return spoken, replacement
    return value, value


def apply_hotwords(text: str, hotwords: list[Hotword]) -> str:
    if not text or not hotwords:
        return text

    tokens = TOKEN_RE.findall(text)
    word_indexes = [index for index, token in enumerate(tokens) if token.strip() and re.search(r"\w", token)]

    for hotword in sorted(hotwords, key=lambda value: len(normalize_hotword(value.spoken)), reverse=True):
        hotword_parts = normalize_hotword(hotword.spoken).split()
        if not hotword_parts:
            continue

        span_size = len(hotword_parts)
        threshold = 0.88 if span_size == 1 else 0.82
        position = 0
        while position <= len(word_indexes) - span_size:
            indexes = word_indexes[position : position + span_size]
            candidate = " ".join(tokens[index] for index in indexes)
            score = SequenceMatcher(None, normalize_hotword(candidate), " ".join(hotword_parts)).ratio()
            if score >= threshold:
                tokens[indexes[0]] = hotword.replacement
                for index in indexes[1:]:
                    tokens[index] = ""
                position += span_size
            else:
                position += 1

    normalized = re.sub(r"\s+", " ", "".join(tokens))
    return re.sub(r"\s+([,.;:!?])", r"\1", normalized).strip()


def normalize_hotword(value: str) -> str:
    parts = re.findall(r"\w+", value.lower())
    return " ".join(NUMBER_WORDS.get(part, part) for part in parts)


def main() -> None:
    import uvicorn

    args = parse_args()
    logging.basicConfig(
        level=logging.INFO if args.debug else logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    model_dir = Path(args.model_dir).expanduser().resolve()
    LOGGER.warning(
        "starting ONNX ASR worker on %s:%s model=%s dir=%s provider=%s",
        args.host,
        args.port,
        args.model_name,
        model_dir,
        args.provider,
    )
    app = create_app(model_dir, args.model_name, args.provider)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
