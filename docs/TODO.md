# DeskScribe TODO

## Native ONNX Runtime

- Add more real shared WAV fixtures for native-vs-`onnx-asr` comparison. (One fixture exists and passes; the comparison harness is `scripts/compare_native_onnx.py`.)
- Fix any preprocessing, tensor shape, or TDT decoding differences found by future fixture comparisons. (The initial fixture currently matches.)
- Continue native performance work; preprocessing uses Accelerate and decoder buffer reuse is in place, and the encoder path is the main remaining cost.

## Model Distribution

- Add richer first-run UI for model download state, failures, and retry guidance. (Status-menu progress, first-run overlay, failure alert, and retry-on-failure menu item exist; richer Preferences UI is still pending.)

## Future Model Types

- Benchmark Moonshine tiny/base through `sherpa-onnx` on DeskScribe WAV fixtures.
- Compare Whisper tiny/base or Distil-Whisper against the same fixtures through an existing mature runtime.
- Run a standalone WhisperKit/CoreML spike on shared fixtures before adding a production CoreML runtime.
- Prototype CTC model support before adding another transducer/RNNT or Whisper-style native decoder.
- Add runtime selection based on installed model package manifests instead of only validating the current native ONNX family.

## App Packaging

- Add first-run UI/status for model download progress and failures. (Status menu progress, first-run overlay, and failure alert are implemented; richer Preferences UI still pending.)

## Settings UX

- Add richer Model pane controls for runtime/model download state and model update/retry controls.
- Add retention settings for transcript history.
- Preserve the current native ONNX simplification where repository/file fields are hidden unless a Python custom model is relevant.

## Vocabulary Management

- Allow editing individual vocabulary entries in place from the list.
- Keep compatibility with the existing stored vocabulary format or add a one-time migration if the storage format changes.
- Add a clear preview/confirmation before applying imported vocabulary changes.
- Expand tests for migration behavior.

## Transcript History

- Add retention settings to auto-clear history after a configurable number of days.
- Decide whether transcript history is enabled by default and document the privacy tradeoff clearly in the UI.
- Store history in a local app-support location that is not synced or uploaded by the app.
- Make failed, cancelled, empty, and partial preview transcripts not appear in history unless explicitly desired later.

## Usage Stats

- Handle history clearing and retention cleanup so stats are either recalculated or explicitly scoped to retained history.

## Launch At Login

- Test launch-at-login behavior for both `DeskScribe` and `DeskScribe ONNX` bundle identifiers.

## Cleanup

- Remove `asr_worker_onnx.py` after native quality and performance are accepted.
- Update README once native ONNX becomes the default runtime.
- Keep `docs/NATIVE_ONNX.md` current until the migration is complete.
