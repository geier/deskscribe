# DeskScribe TODO

## Priority 1: User Installation Story

- Decide final user-facing app name for distribution. Prefer `DeskScribe.app` over `DeskScribe ONNX.app` unless we still need a parallel technical variant.
- Build a minimal DMG release pipeline, e.g. `scripts/build_release_dmg.sh`, producing `dist/DeskScribe-<version>-arm64.dmg` plus SHA256.
- Design the DMG as a normal Mac install experience: app icon, Applications shortcut, and drag-to-install layout.
- Add a first-run setup flow that explains and checks Microphone permission, Accessibility permission, and local model availability.
- Add an explicit `Download Selected Model` action in the app, while keeping lazy first-use download as a fallback.
- Show model download state, failures, and retry controls in the app UI before the first dictation attempt.
- Update README installation docs to lead with the DMG flow: download, drag to Applications, open, approve permissions, download model.
- Keep Homebrew Cask as the power-user install path and align it with the final app name.
- Plan Developer ID signing and notarization for public macOS distribution.
- Plan Sparkle or another update mechanism after the first DMG release path is stable.

## Native ONNX Runtime

- Add more real shared WAV fixtures for native-vs-`onnx-asr` comparison. (One fixture exists and passes; the comparison harness is `scripts/compare_native_onnx.py`.)
- Fix any preprocessing, tensor shape, or TDT decoding differences found by future fixture comparisons. (The initial fixture currently matches.)
- Continue native performance work; preprocessing uses Accelerate and decoder buffer reuse is in place, and the encoder path is the main remaining cost.

## Future Model Types

- Build a standalone Moonshine benchmark on DeskScribe WAV fixtures, starting with Tiny/Small or `sherpa-onnx-moonshine-tiny-en-int8` and `sherpa-onnx-moonshine-base-en-int8`.
- Check Moonshine language coverage before exposing it in Preferences; current small documented paths are promising for English but do not replace Parakeet v3 for German dictation.
- Compare WhisperKit tiny/base against the same fixtures as an Apple-native quality and packaging baseline.
- Run a standalone WhisperKit/CoreML spike on shared fixtures before adding a production CoreML runtime.
- Prototype CTC model support before adding another transducer/RNNT or Whisper-style native decoder.
- Add runtime selection based on installed model package manifests instead of only validating the current native ONNX family.

## App Packaging

- Track packaging implementation under `Priority 1: User Installation Story` until the DMG install path is complete.

## Settings UX

- Track model download controls under `Priority 1: User Installation Story` until the first-run install path is complete.
- Add retention settings for transcript history.

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

- Test launch-at-login behavior for the native ONNX app bundle after release installation.

## Cleanup

- Keep `docs/NATIVE_ONNX.md` current until the migration is complete.
