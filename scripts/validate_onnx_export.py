#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate DeskScribe ONNX ASR export artifacts.")
    parser.add_argument("model_dir")
    parser.add_argument("--audio", default=None, help="Optional WAV/FLAC file to transcribe with onnx-asr.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    model_dir = Path(args.model_dir).expanduser().resolve()
    required = [
        "encoder-model.onnx",
        "decoder_joint-model.onnx",
        "vocab.txt",
        "config.json",
        "MODEL_LICENSE.md",
        "mel_fbanks_nemo128.bin",
    ]
    missing = [name for name in required if not (model_dir / name).exists()]
    if missing:
        raise SystemExit(f"Missing required export artifacts: {', '.join(missing)}")

    license_text = (model_dir / "MODEL_LICENSE.md").read_text(encoding="utf-8")
    required_license_terms = ["CC BY 4.0", "primeline/parakeet-primeline", "nvidia/parakeet-tdt-0.6b-v3"]
    missing_terms = [term for term in required_license_terms if term not in license_text]
    if missing_terms:
        raise SystemExit(f"MODEL_LICENSE.md is missing required attribution terms: {', '.join(missing_terms)}")

    config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    mel_filterbank = config.get("mel_filterbank", {})
    if mel_filterbank.get("file") != "mel_fbanks_nemo128.bin":
        raise SystemExit("config.json is missing mel_filterbank.file=mel_fbanks_nemo128.bin")
    if mel_filterbank.get("rows") != 257 or mel_filterbank.get("columns") != 128:
        raise SystemExit("config.json has unexpected mel_filterbank dimensions")
    expected_mel_size = 257 * 128 * 4
    actual_mel_size = (model_dir / "mel_fbanks_nemo128.bin").stat().st_size
    if actual_mel_size != expected_mel_size:
        raise SystemExit(f"mel_fbanks_nemo128.bin has size {actual_mel_size}, expected {expected_mel_size}")

    import onnx

    for name in ["encoder-model.onnx", "decoder_joint-model.onnx"]:
        path = model_dir / name
        onnx.checker.check_model(str(path), full_check=False)
        model = onnx.load(str(path), load_external_data=False)
        inputs = [value.name for value in model.graph.input]
        outputs = [value.name for value in model.graph.output]
        print(f"{name}: {len(model.graph.node)} nodes, inputs={inputs}, outputs={outputs}")
    print("MODEL_LICENSE.md: attribution metadata present")
    print("mel_fbanks_nemo128.bin: preprocessing constants present")

    if not args.audio:
        print("Artifact validation complete. Pass --audio to run an onnx-asr transcription smoke test.")
        return

    try:
        import onnx_asr
    except ImportError as exc:
        raise SystemExit("Install onnx-asr first: python -m pip install 'onnx-asr[cpu]'") from exc

    model = onnx_asr.load_model("nemo-parakeet-tdt-0.6b-v3", path=str(model_dir), providers=["CPUExecutionProvider"])
    result = model.recognize(args.audio)
    print(result.text if hasattr(result, "text") else result)


if __name__ == "__main__":
    main()
