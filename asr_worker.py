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
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from transcribe_mic import MODEL_FILE, MODEL_REPO, load_model, transcribe_file


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
LOGGER = logging.getLogger("asr_worker")
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a local HTTP worker for primeline/parakeet-primeline transcription."
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Bind host. Default: {DEFAULT_HOST}")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Bind port. Default: {DEFAULT_PORT}")
    parser.add_argument(
        "--device",
        default="cpu",
        choices=["cpu", "mps"],
        help="Torch device to run inference on. CPU is safest on macOS. Default: cpu",
    )
    parser.add_argument(
        "--cache-dir",
        default=None,
        help="Optional Hugging Face cache directory for the .nemo model file.",
    )
    parser.add_argument(
        "--model-repo",
        default=MODEL_REPO,
        help=f"Hugging Face model repo. Default: {MODEL_REPO}",
    )
    parser.add_argument(
        "--model-file",
        default=MODEL_FILE,
        help=f"Model file in the Hugging Face repo. Default: {MODEL_FILE}",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable worker request/lifecycle logs while keeping NeMo output quiet.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Show NeMo warnings and transcription progress bars.",
    )
    return parser.parse_args()


def create_app(
    cache_dir: str | None = None,
    device: str = "cpu",
    quiet: bool = True,
    model_repo: str = MODEL_REPO,
    model_file: str = MODEL_FILE,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        LOGGER.info(
            "loading model repo=%s file=%s device=%s cache_dir=%s quiet=%s",
            model_repo,
            model_file,
            device,
            cache_dir,
            quiet,
        )
        app.state.model = load_model(cache_dir, device, quiet, model_repo=model_repo, model_file=model_file)
        app.state.transcribe_lock = threading.Lock()
        app.state.device = device
        app.state.model_repo = model_repo
        app.state.model_file = model_file
        LOGGER.info("model loaded")
        yield

    app = FastAPI(title="Parakeet ASR Worker", lifespan=lifespan)

    @app.get("/health")
    def health() -> dict[str, Any]:
        LOGGER.info("health check")
        return {
            "status": "ready",
            "model": app.state.model_repo,
            "model_file": app.state.model_file,
            "device": app.state.device,
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
            wav_path = Path(handle.name)
            while chunk := await file.read(1024 * 1024):
                handle.write(chunk)

        try:
            try:
                lock = app.state.transcribe_lock
                with lock:
                    text = transcribe_file(model, wav_path, quiet)
                text = apply_hotwords(text, hotwords)
            except Exception as exc:
                LOGGER.exception("transcribe failed")
                raise HTTPException(status_code=422, detail=f"Transcription failed: {exc}") from exc
            LOGGER.info("transcribe complete characters=%s", len(text))
            return {"text": text}
        finally:
            await file.close()
            try:
                os.unlink(wav_path)
            except FileNotFoundError:
                pass

    return app


def parse_vocabulary(value: str | None) -> list[str]:
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

    seen: set[str] = set()
    words: list[str] = []
    for candidate in candidates:
        word = candidate.strip()
        if not word:
            continue
        key = normalize_hotword(word)
        if key and key not in seen:
            seen.add(key)
            words.append(word)
    return words


def apply_hotwords(text: str, hotwords: list[str]) -> str:
    if not text or not hotwords:
        return text

    tokens = TOKEN_RE.findall(text)
    word_indexes = [index for index, token in enumerate(tokens) if token.strip() and re.search(r"\w", token)]

    for hotword in sorted(hotwords, key=lambda value: len(normalize_hotword(value)), reverse=True):
        hotword_parts = normalize_hotword(hotword).split()
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
                tokens[indexes[0]] = hotword
                for index in indexes[1:]:
                    tokens[index] = ""
                position += span_size
            else:
                position += 1

    return re.sub(r"\s+([,.;:!?])", r"\1", "".join(tokens)).strip()


def normalize_hotword(value: str) -> str:
    parts = re.findall(r"\w+", value.lower())
    return " ".join(NUMBER_WORDS.get(part, part) for part in parts)


def main() -> None:
    import uvicorn

    args = parse_args()
    logging.basicConfig(
        level=logging.INFO if args.verbose or args.debug else logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    LOGGER.warning(
        "starting ASR worker on %s:%s model=%s file=%s",
        args.host,
        args.port,
        args.model_repo,
        args.model_file,
    )
    app = create_app(
        args.cache_dir,
        args.device,
        quiet=not args.verbose,
        model_repo=args.model_repo,
        model_file=args.model_file,
    )
    uvicorn.run(app, host=args.host, port=args.port, log_level="info" if args.verbose else "warning")


if __name__ == "__main__":
    main()
