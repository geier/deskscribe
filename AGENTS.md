# Agent Handoff

## Current Goal

Make DeskScribe's first public user installation story work well, with Homebrew Cask as the primary install path.

## Current Branch

- Branch: `native-onnx-parallel`
- Latest completed commits before this handoff:
  - `7359fd7 Simplify model details in preferences`
  - `2b2e566 Prioritize user installation story`

## Important Context

- DeskScribe is now a native ONNX-only macOS menu bar app.
- The legacy Python worker runtime has been removed.
- Python remains only for model export, packaging, validation, upload, and comparison tooling.
- The app currently installs as `/Applications/DeskScribe.app`.
- User-facing install direction has changed: Homebrew Cask should be the main installation path for now. DMG should be treated as a later secondary distribution option.
- Model weights must not be bundled in the app or Homebrew package. The app downloads model packages on demand from Hugging Face.
- Current app runtime supports `runtime_type=onnxruntime` and `model_type=nemo-conformer-tdt`.
- ONNX Runtime is bundled into app builds by `scripts/embed_onnxruntime.sh`.
- Release builds are arm64-only with the current Homebrew ONNX Runtime setup.
- There is an unrelated untracked file, `docs/PROCUBE_GATEWAY_REQUIREMENTS.md`. Do not modify, delete, or commit it unless explicitly asked.

## Priority 1 Work

Tasks are tracked in `docs/TODO.md`. Start with `Priority 1: User Installation Story`, which currently makes Homebrew Cask the primary user installation path and keeps DMG as a later secondary distribution option.

Do not duplicate or replace the TODO list here. Update `docs/TODO.md` as priorities change.

## Useful Commands

Build debug app:

```bash
./scripts/build_debug.sh
```

Build release app:

```bash
./scripts/build_release.sh
```

Install release app locally:

```bash
./scripts/install_release_app.sh
```

If installation is blocked because the app is running:

```bash
osascript -e 'tell application "DeskScribe" to quit'
./scripts/install_release_app.sh
```

Check branch status:

```bash
git status --short --branch
git log --oneline -3
```

## Current App Details

- Bundle ID: `local.DeskScribe`
- Display name: `DeskScribe`
- Installed app path: `/Applications/DeskScribe.app`
- Log path: `~/Library/Logs/DeskScribe/DeskScribe.log`
- Model install root: `~/Library/Application Support/DeskScribe/Models/`
- LaunchAgent path for login startup: `~/Library/LaunchAgents/local.DeskScribe.startup.plist`

## Current Model Presets

- Default: `NVIDIA Parakeet TDT 0.6B v3 Multilingual ONNX`
  - repo/id: `nvidia-parakeet-tdt-0.6b-v3-onnx`
  - version: `v1`
  - languages: `25 European languages`
  - best for: `General multilingual dictation`
- PrimeLine: `DeskScribe PrimeLine ONNX`
  - repo/id: `parakeet-primeline-onnx`
  - version: `v1`
  - languages: `Multilingual`
  - best for: `German dictation`
  - notes: `Optimized for German dictation while retaining multilingual Parakeet v3 support.`
- English: `NVIDIA Parakeet TDT 0.6B v2 English ONNX`
  - repo/id: `nvidia-parakeet-tdt-0.6b-v2-onnx`
  - version: `v1`
  - languages: `English`
  - best for: `English-only dictation`

## Editing Guidance

- Prefer small, direct changes.
- Do not reintroduce Python as an app runtime.
- Do not bundle model weights into the app or cask.
- Preserve the established native ONNX runtime path unless implementing a clearly separate runtime adapter.
- Commit and push completed task slices when appropriate.
- Do not touch unrelated untracked or dirty files.
