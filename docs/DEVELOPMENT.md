# DeskScribe Development

## Build

Install ONNX Runtime with Homebrew:

```bash
brew install onnxruntime
```

Build the debug app:

```bash
scripts/build_debug.sh
```

Build the release app:

```bash
scripts/build_release.sh
```

Package a Homebrew-ready release ZIP and SHA256:

```bash
VERSION=0.1.0 scripts/package_homebrew_release.sh
```

This writes `dist/DeskScribe-0.1.0-macos.zip` and `dist/DeskScribe-0.1.0-macos.zip.sha256`.

Install the release app locally:

```bash
scripts/install_release_app.sh
```

The installed app path is:

```text
/Applications/DeskScribe.app
```

Logs are written to:

```text
~/Library/Logs/DeskScribe/DeskScribe.log
```

## Xcode

The Xcode project lives at:

```bash
macos/DeskScribe/DeskScribe.xcodeproj
```

Open it with:

```bash
open macos/DeskScribe/DeskScribe.xcodeproj
```

The main development scheme is `DeskScribe`.

## Model Tooling

Python is only used for development tooling: exporting NeMo checkpoints to ONNX, validating exported packages, packaging ZIP manifests, and uploading model artifacts.

```bash
/opt/homebrew/bin/python3.13 -m venv .venv
.venv/bin/python -m pip install --upgrade pip setuptools wheel
.venv/bin/python -m pip install -r requirements-onnx.txt -r requirements-hf.txt
```

Export, validate, and package a model:

```bash
.venv/bin/python scripts/export_nemo_onnx.py --output-dir models/parakeet-primeline-onnx
.venv/bin/python scripts/validate_onnx_export.py models/parakeet-primeline-onnx --fixtures docs/onnx-fixtures.example.json
.venv/bin/python scripts/package_onnx_model.py --version v1 --repo geier/deskscribe-parakeet-primeline-onnx
```

Compare native app output against `onnx-asr`:

```bash
.venv/bin/python scripts/compare_native_onnx.py \
  models/parakeet-primeline-onnx \
  --fixtures docs/onnx-fixtures.example.json \
  --native-app /path/to/DeskScribe.app \
  --repo-root /path/to/deskscribe
```

## Homebrew Cask

The cask lives at:

```bash
Casks/deskscribe.rb
```

After publishing a release, update the cask version and sha256. It downloads:

```ruby
url "https://github.com/geier/deskscribe/releases/download/v#{version}/DeskScribe-#{version}-macos.zip"
```

Install from this repository as a tap with:

```bash
brew tap geier/deskscribe https://github.com/geier/deskscribe
brew install --cask deskscribe
```
