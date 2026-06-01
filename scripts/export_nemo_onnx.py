#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


DEFAULT_MODEL_REPO = "primeline/parakeet-primeline"
DEFAULT_MODEL_FILE = "2_95_WER.nemo"
DEFAULT_OUTPUT_DIR = "models/parakeet-primeline-onnx"
BASE_MODEL_REPO = "nvidia/parakeet-tdt-0.6b-v3"
CC_BY_4_URL = "https://creativecommons.org/licenses/by/4.0/"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export the DeskScribe NeMo ASR model to ONNX.")
    parser.add_argument("--model-repo", default=DEFAULT_MODEL_REPO)
    parser.add_argument("--model-file", default=DEFAULT_MODEL_FILE)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--cache-dir", default=None)
    return parser.parse_args()


def write_model_license(output_dir: Path, model_repo: str, model_file: str) -> None:
    license_path = output_dir / "MODEL_LICENSE.md"
    license_text = f"""# DeskScribe ONNX Model Attribution

This ONNX model package was converted for DeskScribe from the original NeMo checkpoint without retraining.

## Original Model

- Model: `{model_repo}`
- Checkpoint file: `{model_file}`
- Source: https://huggingface.co/{model_repo}
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- License text: {CC_BY_4_URL}
- Model author: Florian Zimmermeister
- Published by: primeLine / primeLine AI Services

## Base Model

- Model: `{BASE_MODEL_REPO}`
- Source: https://huggingface.co/{BASE_MODEL_REPO}
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- License text: {CC_BY_4_URL}

## Changes

- Converted from NVIDIA NeMo `.nemo` format to ONNX.
- Exported as separate encoder and decoder/joint ONNX graphs with accompanying vocabulary and configuration files.
- No training, fine-tuning, or weight modification was performed by this conversion script.

## Notice

This converted package is not an official primeLine or NVIDIA release. Use of the original model and this converted package is governed by CC BY 4.0. Keep this attribution file with redistributed model artifacts.
"""
    license_path.write_text(license_text, encoding="utf-8")
    print(f"Wrote {license_path}")


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    from huggingface_hub import hf_hub_download
    from nemo.collections.asr.models import ASRModel

    nemo_path = hf_hub_download(
        repo_id=args.model_repo,
        filename=args.model_file,
        cache_dir=args.cache_dir,
    )
    print(f"Loading {nemo_path}")
    model = ASRModel.restore_from(nemo_path, map_location="cpu")
    model.eval()

    print(f"Model class: {type(model).__name__}")
    print(f"Export subnets: {model.list_export_subnets()}")
    print(f"Exporting ONNX files to {output_dir}")
    model.export(str(output_dir / "model.onnx"))

    vocab_path = output_dir / "vocab.txt"
    with vocab_path.open("w", encoding="utf-8") as handle:
        for index, token in enumerate([*model.tokenizer.vocab, "<blk>"]):
            handle.write(f"{token} {index}\n")
    print(f"Wrote {vocab_path}")

    config = {
        "model_type": "nemo-conformer-tdt",
        "model_repo": args.model_repo,
        "model_file": args.model_file,
        "base_model_repo": BASE_MODEL_REPO,
        "license": "cc-by-4.0",
        "license_url": CC_BY_4_URL,
        "conversion": "nemo-to-onnx",
        "features_size": 128,
        "subsampling_factor": 8,
        "max_tokens_per_step": 10,
    }
    config_path = output_dir / "config.json"
    with config_path.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    print(f"Wrote {config_path}")
    write_model_license(output_dir, args.model_repo, args.model_file)

    expected = ["encoder-model.onnx", "decoder_joint-model.onnx", "vocab.txt", "config.json", "MODEL_LICENSE.md"]
    missing = [name for name in expected if not (output_dir / name).exists()]
    if missing:
        raise RuntimeError(f"Export incomplete, missing: {', '.join(missing)}")
    print("ONNX export complete")


if __name__ == "__main__":
    main()
