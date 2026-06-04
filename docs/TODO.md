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

- Update release packaging so the Brew cask installs only the app, not the model.
- Add first-run UI/status for model download progress and failures. (Status menu progress, first-run overlay, and failure alert are implemented; richer Preferences UI still pending.)

## Settings UX

- Split Preferences into multiple panes instead of keeping every setting on one screen.
- Add a General pane for hotkey, trigger mode, paste/clipboard behavior, permissions, and launch-at-login.
- Add a Model pane for runtime/model download state, model selection, and model update/retry controls.
- Add a Vocabulary pane for vocabulary aliases, word replacement rules, import/export, validation, and help.
- Add a History & Stats pane for transcript history, usage stats, retention, and clearing controls.
- Preserve the current native ONNX simplification where repository/file fields are hidden unless a Python custom model is relevant.

## Vocabulary Management

- Replace the single raw vocabulary text area with a structured editor.
- Support adding a new plain word through a small input form and show saved words in a list below.
- Support adding replacement rules like `do this` -> `instead of that` through separate phrase and replacement fields.
- Keep both vocabulary item types: plain words and replacement aliases.
- Allow editing and deleting individual vocabulary entries from the list.
- Validate entries inline and surface malformed/duplicate rules without blocking unrelated valid entries.
- Keep compatibility with the existing stored vocabulary format or add a one-time migration if the storage format changes.
- Add JSON export for the vocabulary list, including item type, phrase, replacement, and any future metadata.
- Add JSON import with validation, duplicate handling, and a clear preview/confirmation before applying changes.
- Add tests for parsing, validation, import/export, and migration behavior.

## Transcript History

- Persist completed dictation transcripts locally with timestamp, character count, word count, and app variant/runtime if useful.
- Add a History view that lists previous transcripts with search/filter and copy actions.
- Add a clear-history action with confirmation.
- Add retention settings to auto-clear history after a configurable number of days.
- Decide whether transcript history is enabled by default and document the privacy tradeoff clearly in the UI.
- Store history in a local app-support location that is not synced or uploaded by the app.
- Make failed, cancelled, empty, and partial preview transcripts not appear in history unless explicitly desired later.

## Usage Stats

- Track words dictated per session, today, this week, and all time.
- Track dictation count and total dictated characters as supporting stats.
- Derive stats from transcript history where possible to avoid separate data drift.
- Handle history clearing and retention cleanup so stats are either recalculated or explicitly scoped to retained history.
- Add a lightweight Stats UI in the History & Stats pane.

## Launch At Login

- Add a launch-at-login setting in Preferences.
- Implement login item registration using the modern macOS `ServiceManagement` APIs.
- Reflect the real system login-item state in the UI, including failures or missing permission/state mismatches.
- Test launch-at-login behavior for both `DeskScribe` and `DeskScribe ONNX` bundle identifiers.

## Cleanup

- Remove `asr_worker_onnx.py` after native quality and performance are accepted.
- Update README once native ONNX becomes the default runtime.
- Keep `docs/NATIVE_ONNX.md` current until the migration is complete.
