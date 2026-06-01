# Native ONNX Spike

This branch keeps the existing Python/NeMo app intact and adds a parallel `DeskScribeONNX` target for native ONNX work.

## Current Status

- `ParakeetDictation` builds the stable `DeskScribe.app`.
- `DeskScribeONNX` builds a parallel `DeskScribeONNX.app` with a different bundle ID, app name, log path, and worker port.
- The NeMo checkpoint exports successfully to ONNX.
- The exported ONNX artifacts validate successfully.
- `onnx-asr` can load the exported artifacts and transcribe a WAV file successfully.
- `DeskScribeONNX` launches `asr_worker_onnx.py` on port `8766`, so it uses the exported ONNX artifacts instead of the NeMo worker.

`DeskScribeONNX` still uses Python as a temporary ONNX Runtime bridge. The native Swift ONNX inference engine is the next implementation step.

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
```

The encoder uses ONNX external data, so many additional weight files are expected next to `encoder-model.onnx`. The export directory is intentionally ignored by git.

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

## Build Both Apps

```bash
scripts/build_parallel_debug.sh
```

## Run ONNX App

Export the model first, then launch the ONNX app:

```bash
.venv/bin/python scripts/export_nemo_onnx.py --output-dir models/parakeet-primeline-onnx
launchctl setenv DESKSCRIBE_WORKER_ROOT "/Users/cg/tmp/hosting"
open /var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribeONNX.app
```

Check the ONNX worker:

```bash
curl http://127.0.0.1:8766/health
```

Outputs:

```text
/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribe.app
/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build/Build/Products/Debug/DeskScribeONNX.app
```

## Next Native Runtime Work

- Add ONNX Runtime C/Objective-C or Swift package integration.
- Port the `onnx-asr` Parakeet preprocessing and TDT greedy decoder to Swift.
- Load `encoder-model.onnx`, `decoder_joint-model.onnx`, `vocab.txt`, and `config.json` from the app bundle or a local model directory.
- Replace `asr_worker_onnx.py` with an in-process native runtime behind the existing `WorkerManager` API.
