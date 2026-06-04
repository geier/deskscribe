# Native ONNX Spike

This branch keeps the existing Python/NeMo app intact and adds a parallel `DeskScribeONNX` target for native ONNX work.

## Current Status

- `ParakeetDictation` builds the stable `DeskScribe.app`.
- `DeskScribeONNX` builds a parallel `DeskScribeONNX.app` with a different bundle ID, app name, log path, and worker port.
- The NeMo checkpoint exports successfully to ONNX.
- The exported ONNX artifacts validate successfully.
- `onnx-asr` can load the exported artifacts and transcribe a WAV file successfully.
- `DeskScribeONNX` loads the exported ONNX sessions in-process through ONNX Runtime.
- `DeskScribeONNX` validates the ONNX model package directly and no longer needs `.venv/bin/python` or `asr_worker_onnx.py` at startup.
- `DeskScribeONNX` now loads `vocab.txt` natively and runs a first native transcription path from PCM16 WAV input through preprocessing, ONNX encoder inference, TDT greedy decoding, and text reconstruction.
- The export package now includes `mel_fbanks_nemo128.bin`, the `onnx-asr` Nemo 128-bin mel filterbank matrix required for native preprocessing.
- The native runtime checks `~/Library/Application Support/DeskScribe/Models/parakeet-primeline-onnx-v1` first, then falls back to the development export under `models/parakeet-primeline-onnx`.
- If no valid local model package exists, `DeskScribeONNX` fetches the model manifest from Hugging Face, downloads the ZIP archive, verifies SHA256, and installs it under `~/Library/Application Support/DeskScribe/Models/`.

`DeskScribeONNX` now starts through `NativeONNXRuntime` and loads ONNX Runtime sessions in-process. Native transcription is implemented as an MVP and still needs accuracy/performance comparison against `onnx-asr` before replacing the stable Python app.

## Export Model

```bash
.venv/bin/python scripts/export_nemo_onnx.py --output-dir models/parakeet-primeline-onnx
```

The export produces:

```text
encoder-model.onnx
decoder_joint-model.onnx
vocab.txt
config.json
MODEL_LICENSE.md
mel_fbanks_nemo128.bin
```

The encoder uses ONNX external data, so many additional weight files are expected next to `encoder-model.onnx`. `mel_fbanks_nemo128.bin` is a raw little-endian float32 matrix with shape `257 x 128`. The export directory is intentionally ignored by git.

## Redistribution License

Both the fine-tuned model and the NVIDIA base model declare `cc-by-4.0` on Hugging Face. The ONNX export can be redistributed if the package keeps attribution, marks the `.nemo` to ONNX conversion, links the CC BY 4.0 license, and avoids implying primeLine or NVIDIA endorsement.

The export script writes `MODEL_LICENSE.md` into the model package with attribution for:

- `primeline/parakeet-primeline`
- `nvidia/parakeet-tdt-0.6b-v3`
- CC BY 4.0: https://creativecommons.org/licenses/by/4.0/

## Validate Export

```bash
.venv/bin/python -m pip install -r requirements-onnx.txt
.venv/bin/python scripts/validate_onnx_export.py models/parakeet-primeline-onnx
```

Optional transcription smoke test:

```bash
.venv/bin/python scripts/validate_onnx_export.py models/parakeet-primeline-onnx --audio /path/to/audio.wav
```

Shared WAV fixture baseline:

```bash
.venv/bin/python scripts/validate_onnx_export.py \
  models/parakeet-primeline-onnx \
  --fixtures docs/onnx-fixtures.example.json
```

To generate a baseline manifest from one or more audio files:

```bash
.venv/bin/python scripts/validate_onnx_export.py \
  models/parakeet-primeline-onnx \
  --audio /path/to/audio.wav \
  --write-results /tmp/deskscribe-onnx-fixtures.json
```

The fixture manifest stores `onnx-asr` output as the expected text. The native runtime should use the same WAV fixtures for accuracy comparisons once a native CLI/smoke-test entry point exists.

Native ONNX smoke test from the built app executable:

```bash
/path/to/DeskScribeONNX.app/Contents/MacOS/DeskScribeONNX \
  --repo-root /path/to/deskscribe \
  --native-onnx-smoke-test /path/to/audio.wav
```

The command prints JSON results to stdout and runtime progress to stderr. `--native-onnx-smoke-test` can be passed more than once to transcribe multiple shared WAV fixtures.

Native-vs-`onnx-asr` comparison harness:

```bash
scripts/compare_native_onnx.py \
  models/parakeet-primeline-onnx \
  --fixtures docs/onnx-fixtures.example.json \
  --native-app /path/to/DeskScribeONNX.app \
  --repo-root /path/to/deskscribe
```

The comparison script runs `onnx-asr` and the native smoke-test CLI on the same WAV files, prints per-fixture output, and exits non-zero on transcript differences or native errors.

## Package Model For Download

If the original `.nemo` checkpoint needs to be mirrored first, use:

```bash
.venv/bin/python scripts/hf_model_transfer.py \
  --preset primeline-parakeet \
  --target-repo geier/deskscribe-parakeet-primeline-onnx \
  --create-repo
```

For other Parakeet checkpoints, either use another preset such as `nvidia-parakeet-tdt-0.6b-v3` or pass `--source-repo` and `--filename` explicitly. The script downloads exactly one file and uploads that same file to the target repo.

```bash
.venv/bin/python scripts/package_onnx_model.py \
  --version v1 \
  --repo geier/deskscribe-parakeet-primeline-onnx
```

The packaging script writes a versioned zip archive, a `.sha256` file, and a manifest under `dist/models/`. The archive keeps all ONNX external-data weight files next to `encoder-model.onnx`, so it can be downloaded and extracted as one complete model package. The manifest shape is documented in `docs/model-package-manifest.schema.json` and includes runtime type, model type, preprocessing metadata, decoding metadata, file list, size, SHA256, and license fields.

The app expects the `v1` manifest at:

```text
https://huggingface.co/geier/deskscribe-parakeet-primeline-onnx/resolve/main/parakeet-primeline-onnx-v1.manifest.json
```

## Build Both Apps

```bash
scripts/build_parallel_debug.sh
```

## Run ONNX App

Install or export the model first, then launch the ONNX app. The preferred installed model directory is:

```text
~/Library/Application Support/DeskScribe/Models/parakeet-primeline-onnx-v1
```

For development, the app falls back to `models/parakeet-primeline-onnx` under the repo root:

```bash
.venv/bin/python scripts/export_nemo_onnx.py --output-dir models/parakeet-primeline-onnx
launchctl setenv DESKSCRIBE_WORKER_ROOT "/Users/cg/tmp/hosting"
open /var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribeONNX.app
```

Check the ONNX app log for native session and vocabulary loading:

```bash
open ~/Library/Logs/DeskScribeONNX/DeskScribeONNX.log
```

Outputs:

```text
/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribe.app
/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribeONNX.app
```

## Next Native Runtime Work

- `TranscriptionRuntime` now defines the app/runtime boundary used by `AppDelegate`.
- `NativeONNXRuntime` validates the exported model package and loads the encoder and decoder/joint ONNX sessions in-process through ONNX Runtime's C API.
- `NativeONNXRuntime` loads the vocabulary natively and identifies the blank token.
- `NativeONNXRuntime.transcribe(...)` loads the app's 16 kHz mono PCM16 WAV files and executes the native ONNX path end-to-end.
- The ONNX package now carries the fixed Nemo mel filterbank constants needed by the Swift preprocessor.
- Local development currently links the ONNX target against Homebrew's `onnxruntime` package in `/opt/homebrew/opt/onnxruntime`.
- Compare native preprocessing/decoding output against `onnx-asr` on shared WAV fixtures and continue encoder/decoder performance work.
- Publish the model archive and manifest to Hugging Face once the local ONNX export/package is available.
- Remove `asr_worker_onnx.py` once native transcription quality and performance are accepted.
