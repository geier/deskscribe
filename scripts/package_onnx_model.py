#!/usr/bin/env python3
import argparse
import hashlib
import json
import zipfile
from datetime import UTC, datetime
from pathlib import Path


DEFAULT_MODEL_DIR = "models/parakeet-primeline-onnx"
DEFAULT_OUTPUT_DIR = "dist/models"
DEFAULT_MODEL_ID = "parakeet-primeline-onnx"
REQUIRED_FILES = [
    "encoder-model.onnx",
    "decoder_joint-model.onnx",
    "vocab.txt",
    "config.json",
    "MODEL_LICENSE.md",
    "mel_fbanks_nemo128.bin",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package a DeskScribe ONNX model directory for download distribution.")
    parser.add_argument("--model-dir", default=DEFAULT_MODEL_DIR)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--version", required=True, help="Model package version, for example v1.")
    parser.add_argument("--repo", default=None, help="Optional Hugging Face repo id for manifest metadata.")
    parser.add_argument(
        "--compression",
        choices=("store", "deflate"),
        default="store",
        help="ZIP compression mode. 'store' is faster and avoids recompressing large float weights.",
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_model_dir(model_dir: Path) -> None:
    missing = [name for name in REQUIRED_FILES if not (model_dir / name).exists()]
    if missing:
        raise SystemExit(f"Missing required model files: {', '.join(missing)}")


def package_files(model_dir: Path, archive_path: Path, compression: str) -> None:
    method = zipfile.ZIP_STORED if compression == "store" else zipfile.ZIP_DEFLATED
    kwargs = {"compression": method}
    if method == zipfile.ZIP_DEFLATED:
        kwargs["compresslevel"] = 6

    files = sorted(path for path in model_dir.iterdir() if path.is_file())
    with zipfile.ZipFile(archive_path, "w", **kwargs) as archive:
        for path in files:
            archive.write(path, arcname=path.name)


def main() -> None:
    args = parse_args()
    model_dir = Path(args.model_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    validate_model_dir(model_dir)

    config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    archive_name = f"{args.model_id}-{args.version}.zip"
    archive_path = output_dir / archive_name
    package_files(model_dir, archive_path, args.compression)
    archive_sha256 = sha256_file(archive_path)
    sha256_path = archive_path.with_suffix(archive_path.suffix + ".sha256")
    sha256_path.write_text(f"{archive_sha256}  {archive_name}\n", encoding="utf-8")

    manifest = {
        "id": args.model_id,
        "version": args.version,
        "runtime_type": "onnxruntime",
        "model_type": config.get("model_type", "nemo-conformer-tdt"),
        "archive": archive_name,
        "sha256": archive_sha256,
        "size": archive_path.stat().st_size,
        "source_model": config.get("model_repo"),
        "source_file": config.get("model_file"),
        "base_model": config.get("base_model_repo"),
        "license": config.get("license"),
        "license_url": config.get("license_url"),
        "created_at": datetime.now(UTC).isoformat(),
        "required_files": REQUIRED_FILES,
        "preprocessing": {
            "sample_rate": config.get("sample_rate", 16000),
            "features": config.get("features_size", 128),
            "subsampling_factor": config.get("subsampling_factor"),
            "mel_filterbank": config.get("mel_filterbank"),
        },
        "decoding": {
            "type": config.get("decoding_type", "tdt_greedy"),
            "blank_token": config.get("blank_token", "<blk>"),
            "max_tokens_per_step": config.get("max_tokens_per_step", 10),
        },
    }
    if args.repo:
        manifest["huggingface_repo"] = args.repo
        manifest["archive_url"] = f"https://huggingface.co/{args.repo}/resolve/main/{archive_name}"

    manifest_path = output_dir / f"{args.model_id}-{args.version}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Archive:  {archive_path}")
    print(f"Manifest: {manifest_path}")
    print(f"SHA256:   {sha256_path}")


if __name__ == "__main__":
    main()
