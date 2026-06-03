# DeskScribe TODO

## Native ONNX Runtime

- Compare native `DeskScribeONNX` transcription output against `onnx-asr` on shared WAV fixtures.
- Fix any preprocessing, tensor shape, or TDT decoding differences found by the comparison.
- Continue native performance work; preprocessing uses Accelerate now, and the encoder/decoder path is the main remaining cost.
- Add a native transcription smoke test path that can run against a local exported ONNX package.

## Model Distribution

- Package `models/parakeet-primeline-onnx` as a single versioned archive for download. (Initial `v1` package generated locally.)
- Generate `manifest.json` with model version, source model, archive URL, size, SHA256, and license metadata. (Initial `v1` manifest generated locally.)
- Publish the model archive and manifest to a Hugging Face model repository. Blocked locally until the ONNX export/package exists again and Hugging Face auth is available.
- Add app-side model download, SHA256 verification, atomic extraction, and retry handling. (Initial download/verify/install path implemented; retry UI still pending.)
- Store downloaded models under `~/Library/Application Support/DeskScribe/Models/`. (Runtime now checks this location.)
- Change `NativeONNXRuntime` to load from the installed model directory before falling back to development paths. (Done for `parakeet-primeline-onnx-v1`.)

## Future Model Types

- Define a model package manifest schema with explicit `model_type`, `runtime_type`, preprocessing, decoding, file list, size, SHA256, and license fields.
- Keep the current native runtime scoped to `nemo-conformer-tdt` packages with compatible ONNX inputs/outputs.
- Evaluate smaller and faster ASR model families for local dictation use.
- Investigate native support for CTC-based ONNX models, which may need a simpler decoder than TDT/RNNT.
- Investigate Whisper-style ONNX models, which need different preprocessing and decoding.
- Investigate CoreML or MLX model variants for better Apple Silicon performance.
- Add runtime selection based on the downloaded model package manifest instead of hard-coding one model family.

## App Packaging

- Bundle ONNX Runtime inside `DeskScribe.app/Contents/Frameworks` or replace the Homebrew path link with a distributable dependency strategy.
- Remove hard-coded `/opt/homebrew/opt/onnxruntime` assumptions from release builds.
- Update release packaging so the Brew cask installs only the app, not the model.
- Add first-run UI/status for model download progress and failures. (Status menu progress is implemented; richer UI still pending.)

## Cleanup

- Remove `asr_worker_onnx.py` after native quality and performance are accepted.
- Update README once native ONNX becomes the default runtime.
- Keep `docs/NATIVE_ONNX.md` current until the migration is complete.
