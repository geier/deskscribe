#!/usr/bin/env python3
import argparse
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ModelPreset:
    source_repo: str
    filename: str
    target_filename: str | None = None


PRESETS = {
    "primeline-parakeet": ModelPreset(
        source_repo="primeline/parakeet-primeline",
        filename="2_95_WER.nemo",
    ),
    "nvidia-parakeet-tdt-0.6b-v3": ModelPreset(
        source_repo="nvidia/parakeet-tdt-0.6b-v3",
        filename="parakeet-tdt-0.6b-v3.nemo",
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download exactly one Hugging Face model file and upload it to another model repo."
    )
    parser.add_argument("--preset", choices=sorted(PRESETS), help="Known Parakeet model preset.")
    parser.add_argument("--source-repo", help="Source Hugging Face repo id, for example primeline/parakeet-primeline.")
    parser.add_argument("--filename", help="Exact source file to download from the source repo.")
    parser.add_argument("--target-repo", required=True, help="Destination Hugging Face repo id.")
    parser.add_argument("--target-path", help="Destination path inside target repo. Defaults to the source filename.")
    parser.add_argument("--cache-dir", default=".hf-cache", help="Local Hugging Face cache directory.")
    parser.add_argument("--revision", default="main", help="Source revision. Defaults to main.")
    parser.add_argument("--target-revision", default="main", help="Target branch/revision. Defaults to main.")
    parser.add_argument("--repo-type", default="model", choices=("model", "dataset", "space"))
    parser.add_argument("--create-repo", action="store_true", help="Create the target repo if it does not exist.")
    parser.add_argument("--private", action="store_true", help="Create target repo as private when --create-repo is used.")
    parser.add_argument("--dry-run", action="store_true", help="Print what would happen without uploading.")
    return parser.parse_args()


def resolve_source(args: argparse.Namespace) -> tuple[str, str, str]:
    preset = PRESETS.get(args.preset) if args.preset else None
    source_repo = args.source_repo or (preset.source_repo if preset else None)
    filename = args.filename or (preset.filename if preset else None)
    target_path = args.target_path or (preset.target_filename if preset else None) or filename

    if not source_repo or not filename or not target_path:
        raise SystemExit("Provide --preset or both --source-repo and --filename.")
    return source_repo, filename, target_path


def main() -> None:
    args = parse_args()
    source_repo, filename, target_path = resolve_source(args)
    cache_dir = Path(args.cache_dir).expanduser().resolve()

    from huggingface_hub import HfApi, hf_hub_download

    print(f"Source:      {source_repo}@{args.revision}:{filename}")
    print(f"Target:      {args.target_repo}@{args.target_revision}:{target_path}")
    print(f"Cache dir:   {cache_dir}")

    local_path = hf_hub_download(
        repo_id=source_repo,
        filename=filename,
        revision=args.revision,
        repo_type=args.repo_type,
        cache_dir=cache_dir,
    )
    local_file = Path(local_path)
    print(f"Downloaded:  {local_file}")
    print(f"Size:        {local_file.stat().st_size} bytes")

    if args.dry_run:
        print("Dry run: upload skipped")
        return

    api = HfApi()
    if args.create_repo:
        api.create_repo(
            repo_id=args.target_repo,
            repo_type=args.repo_type,
            private=args.private,
            exist_ok=True,
        )

    url = api.upload_file(
        path_or_fileobj=str(local_file),
        path_in_repo=target_path,
        repo_id=args.target_repo,
        repo_type=args.repo_type,
        revision=args.target_revision,
        commit_message=f"Upload {target_path}",
    )
    print(f"Uploaded:    {url}")


if __name__ == "__main__":
    main()
