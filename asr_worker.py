#!/usr/bin/env python3
import argparse
import logging
import os
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile

from transcribe_mic import MODEL_FILE, MODEL_REPO, load_model, transcribe_file


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
LOGGER = logging.getLogger("asr_worker")


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
    async def transcribe(file: UploadFile = File(...)) -> dict[str, str]:
        LOGGER.info("transcribe request filename=%s content_type=%s", file.filename, file.content_type)
        model = getattr(app.state, "model", None)
        if model is None:
            raise HTTPException(status_code=503, detail="ASR model is not loaded")

        suffix = Path(file.filename or "").suffix or ".wav"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
            wav_path = Path(handle.name)
            while chunk := await file.read(1024 * 1024):
                handle.write(chunk)

        try:
            text = transcribe_file(model, wav_path, quiet)
            LOGGER.info("transcribe complete characters=%s", len(text))
            return {"text": text}
        finally:
            await file.close()
            try:
                os.unlink(wav_path)
            except FileNotFoundError:
                pass

    return app


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
