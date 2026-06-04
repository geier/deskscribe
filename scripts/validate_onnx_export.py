#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate DeskScribe ONNX ASR export artifacts.")
    parser.add_argument("model_dir")
    parser.add_argument(
        "--audio",
        action="append",
        default=[],
        help="Optional WAV/FLAC file to transcribe with onnx-asr. Can be passed more than once.",
    )
    parser.add_argument(
        "--fixtures",
        default=None,
        help="Optional JSON fixture manifest with items containing path and optional expected text.",
    )
    parser.add_argument(
        "--write-results",
        default=None,
        help="Optional path to write onnx-asr transcription results as a JSON fixture manifest.",
    )
    return parser.parse_args()


def load_fixtures(fixtures_path: Path) -> list[dict[str, str]]:
    raw = json.loads(fixtures_path.read_text(encoding="utf-8"))
    items = raw.get("fixtures", raw) if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        raise SystemExit("Fixture manifest must be a list or an object with a fixtures list.")

    fixtures: list[dict[str, str]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise SystemExit(f"Fixture {index} must be an object.")
        path = item.get("path") or item.get("audio")
        if not isinstance(path, str) or not path:
            raise SystemExit(f"Fixture {index} is missing a path.")
        expected = item.get("expected") or item.get("text")
        fixture = {"path": path}
        if isinstance(expected, str):
            fixture["expected"] = expected
        fixtures.append(fixture)
    return fixtures


def resolve_audio_path(path: str, base_dir: Path | None) -> Path:
    audio_path = Path(path).expanduser()
    if not audio_path.is_absolute() and base_dir is not None:
        audio_path = base_dir / audio_path
    audio_path = audio_path.resolve()
    if not audio_path.exists():
        raise SystemExit(f"Audio fixture does not exist: {audio_path}")
    return audio_path


def transcription_text(result: Any) -> str:
    text = result.text if hasattr(result, "text") else result
    return str(text).strip()


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

    fixtures: list[dict[str, str]] = []
    for audio in args.audio:
        fixtures.append({"path": audio})

    fixture_base_dir: Path | None = None
    if args.fixtures:
        fixture_path = Path(args.fixtures).expanduser().resolve()
        fixture_base_dir = fixture_path.parent
        fixtures.extend(load_fixtures(fixture_path))

    if not fixtures:
        print("Artifact validation complete. Pass --audio or --fixtures to run onnx-asr transcription smoke tests.")
        return

    try:
        import onnx_asr
    except ImportError as exc:
        raise SystemExit("Install onnx-asr first: python -m pip install 'onnx-asr[cpu]'") from exc

    model = onnx_asr.load_model("nemo-parakeet-tdt-0.6b-v3", path=str(model_dir), providers=["CPUExecutionProvider"])
    results = []
    failures = []
    for fixture in fixtures:
        audio_path = resolve_audio_path(fixture["path"], fixture_base_dir)
        text = transcription_text(model.recognize(str(audio_path)))
        expected = fixture.get("expected")
        passed = expected is None or text == expected.strip()
        result = {
            "path": str(audio_path),
            "text": text,
        }
        if expected is not None:
            result["expected"] = expected.strip()
            result["passed"] = passed
        results.append(result)

        status = "PASS" if passed else "FAIL"
        print(f"{status} {audio_path}: {text}")
        if not passed:
            failures.append(result)

    if args.write_results:
        output_path = Path(args.write_results).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps({"fixtures": results}, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote transcription fixture results: {output_path}")

    if failures:
        raise SystemExit(f"{len(failures)} transcription fixture(s) did not match expected text.")


if __name__ == "__main__":
    main()
