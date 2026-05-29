#!/usr/bin/env python3
import argparse
import contextlib
import logging
import os
import tempfile
import warnings
from pathlib import Path
from typing import Any



MODEL_REPO = "primeline/parakeet-primeline"
MODEL_FILE = "2_95_WER.nemo"
SAMPLE_RATE = 16_000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Record from the local microphone and print primeline/parakeet-primeline transcriptions."
    )
    parser.add_argument(
        "--chunk-seconds",
        type=float,
        default=5.0,
        help="Seconds of microphone audio to transcribe per loop. Default: 5.0",
    )
    parser.add_argument(
        "--device",
        default="cpu",
        choices=["cpu", "mps"],
        help="Torch device to run inference on. CPU is safest on macOS. Default: cpu",
    )
    parser.add_argument(
        "--input-device",
        default=None,
        help="Optional sounddevice input device name or index. Use --list-devices to inspect choices.",
    )
    parser.add_argument(
        "--min-rms",
        type=float,
        default=0.003,
        help="Skip chunks quieter than this RMS level. Use 0 to disable. Default: 0.003",
    )
    parser.add_argument(
        "--cache-dir",
        default=None,
        help="Optional Hugging Face cache directory for the .nemo model file.",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List local audio devices and exit.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Show NeMo warnings and transcription progress bars.",
    )
    return parser.parse_args()


def normalize_input_device(input_device: str | None) -> int | str | None:
    if input_device is None:
        return None
    return int(input_device) if input_device.isdigit() else input_device


def configure_quiet_logging() -> None:
    logging.getLogger("nemo_logger").setLevel(logging.ERROR)
    logging.getLogger("pytorch_lightning").setLevel(logging.ERROR)
    logging.getLogger("lightning").setLevel(logging.ERROR)
    warnings.filterwarnings("ignore")

    try:
        from nemo.utils import logging as nemo_logging

        nemo_logging.set_verbosity(nemo_logging.ERROR)
    except Exception:
        pass


@contextlib.contextmanager
def muted_output(enabled: bool):
    if not enabled:
        yield
        return

    with open(os.devnull, "w") as devnull:
        with contextlib.redirect_stdout(devnull), contextlib.redirect_stderr(devnull):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                yield


def load_model(cache_dir: str | None, device_name: str, quiet: bool) -> Any:
    import torch
    from huggingface_hub import hf_hub_download
    from nemo.collections.asr.models import ASRModel

    if quiet:
        configure_quiet_logging()

    if device_name == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("MPS was requested, but torch.backends.mps is not available.")

    model_path = hf_hub_download(
        repo_id=MODEL_REPO,
        filename=MODEL_FILE,
        cache_dir=cache_dir,
    )

    device = torch.device(device_name)
    model = ASRModel.restore_from(model_path, map_location=device)
    model.to(device)
    model.eval()
    return model


def record_chunk(seconds: float, input_device: int | str | None) -> Any:
    import sounddevice as sd

    frames = int(seconds * SAMPLE_RATE)
    audio = sd.rec(
        frames,
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        device=input_device,
    )
    sd.wait()
    return audio.reshape(-1)


def rms(audio: Any) -> float:
    import numpy as np

    return float(np.sqrt(np.mean(np.square(audio))))


def transcribe_audio(model: Any, audio: Any, quiet: bool) -> str:
    import soundfile as sf

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        wav_path = Path(handle.name)

    try:
        sf.write(wav_path, audio, SAMPLE_RATE)
        with muted_output(quiet):
            output = model.transcribe([str(wav_path)])
        first = output[0]
        return getattr(first, "text", first).strip()
    finally:
        try:
            os.unlink(wav_path)
        except FileNotFoundError:
            pass


def main() -> None:
    args = parse_args()

    if args.list_devices:
        import sounddevice as sd

        print(sd.query_devices())
        return

    print(f"Loading {MODEL_REPO}. First run downloads the checkpoint and can take a while.")
    quiet = not args.verbose
    model = load_model(args.cache_dir, args.device, quiet)
    input_device = normalize_input_device(args.input_device)
    print(
        f"Listening on the local microphone in {args.chunk_seconds:g}s chunks at {SAMPLE_RATE} Hz. "
        "Press Ctrl+C to stop."
    )

    try:
        while True:
            audio = record_chunk(args.chunk_seconds, input_device)
            level = rms(audio)

            if args.min_rms > 0 and level < args.min_rms:
                print(f"[silence rms={level:.4f}]", flush=True)
                continue

            text = transcribe_audio(model, audio, quiet)
            if text:
                print(text, flush=True)
            else:
                print("[no transcript]", flush=True)
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
