#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


DEFAULT_NATIVE_APP = "/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribeONNX.app"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare native DeskScribeONNX output against onnx-asr on shared WAV fixtures.")
    parser.add_argument("model_dir", help="Exported ONNX model directory for onnx-asr.")
    parser.add_argument("--fixtures", required=True, help="JSON fixture manifest with WAV paths.")
    parser.add_argument("--native-app", default=DEFAULT_NATIVE_APP, help="Path to DeskScribeONNX.app or its executable.")
    parser.add_argument("--repo-root", default=".", help="Repo root passed to the native smoke-test CLI.")
    parser.add_argument("--write-results", default=None, help="Optional path to write comparison results as JSON.")
    return parser.parse_args()


def load_fixture_paths(fixtures_path: Path) -> list[Path]:
    raw = json.loads(fixtures_path.read_text(encoding="utf-8"))
    items = raw.get("fixtures", raw) if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        raise SystemExit("Fixture manifest must be a list or an object with a fixtures list.")

    paths: list[Path] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise SystemExit(f"Fixture {index} must be an object.")
        value = item.get("path") or item.get("audio")
        if not isinstance(value, str) or not value:
            raise SystemExit(f"Fixture {index} is missing a path.")

        path = Path(value).expanduser()
        if not path.is_absolute():
            path = fixtures_path.parent / path
        path = path.resolve()
        if not path.exists():
            raise SystemExit(f"Audio fixture does not exist: {path}")
        paths.append(path)
    return paths


def native_executable(native_app: Path) -> Path:
    native_app = native_app.expanduser().resolve()
    if native_app.suffix == ".app":
        executable = native_app / "Contents/MacOS/DeskScribeONNX"
    else:
        executable = native_app
    if not executable.exists():
        raise SystemExit(f"Native ONNX executable does not exist: {executable}")
    return executable


def run_onnx_asr_baseline(model_dir: Path, audio_paths: list[Path]) -> dict[str, str]:
    with tempfile.TemporaryDirectory(prefix="deskscribe-onnx-baseline-") as temp_dir:
        output_path = Path(temp_dir) / "baseline.json"
        command = [
            sys.executable,
            "scripts/validate_onnx_export.py",
            str(model_dir),
            "--write-results",
            str(output_path),
        ]
        for path in audio_paths:
            command.extend(["--audio", str(path)])

        subprocess.run(command, check=True)
        raw = json.loads(output_path.read_text(encoding="utf-8"))
        return {item["path"]: item.get("text", "") for item in raw.get("fixtures", [])}


def run_native_smoke_test(executable: Path, repo_root: Path, audio_paths: list[Path]) -> dict[str, dict[str, str | None]]:
    command = [str(executable), "--repo-root", str(repo_root)]
    for path in audio_paths:
        command.extend(["--native-onnx-smoke-test", str(path)])

    completed = subprocess.run(command, check=False, text=True, capture_output=True)
    if completed.stderr:
        print(completed.stderr, end="")
    if completed.returncode not in (0, 1):
        raise SystemExit(f"Native smoke test failed with exit code {completed.returncode}: {completed.stdout}")

    try:
        raw: dict[str, Any] = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Native smoke test did not return JSON: {completed.stdout}") from exc
    return {item["path"]: {"text": item.get("text"), "error": item.get("error")} for item in raw.get("fixtures", [])}


def main() -> None:
    args = parse_args()
    model_dir = Path(args.model_dir).expanduser().resolve()
    fixtures_path = Path(args.fixtures).expanduser().resolve()
    repo_root = Path(args.repo_root).expanduser().resolve()
    audio_paths = load_fixture_paths(fixtures_path)

    baseline = run_onnx_asr_baseline(model_dir, audio_paths)
    native = run_native_smoke_test(native_executable(Path(args.native_app)), repo_root, audio_paths)

    results = []
    failures = []
    for path in audio_paths:
        key = str(path)
        onnx_asr_text = baseline.get(key, "")
        native_result = native.get(key, {"text": None, "error": "missing native result"})
        native_text = native_result.get("text")
        error = native_result.get("error")
        passed = error is None and (native_text or "").strip() == onnx_asr_text.strip()
        result = {
            "path": key,
            "passed": passed,
            "onnx_asr": onnx_asr_text,
            "native": native_text,
            "native_error": error,
        }
        results.append(result)
        if not passed:
            failures.append(result)

        status = "PASS" if passed else "FAIL"
        print(f"{status} {key}")
        print(f"  onnx-asr: {onnx_asr_text}")
        print(f"  native:   {native_text if native_text is not None else error}")

    if args.write_results:
        output_path = Path(args.write_results).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps({"fixtures": results}, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote comparison results: {output_path}")

    if failures:
        raise SystemExit(f"{len(failures)} native fixture comparison(s) failed.")


if __name__ == "__main__":
    main()
