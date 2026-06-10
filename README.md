# DeskScribe

<p align="center">
  <img src="macos/DeskScribe/DeskScribe/Resources/DeskScribeIcon.png" alt="DeskScribe app icon" width="128" height="128">
</p>

DeskScribe is a macOS menu bar dictation app that runs local speech recognition through a native [ONNX Runtime](https://onnxruntime.ai/) path.

## Install

Homebrew is the primary install path:

```bash
brew tap geier/deskscribe https://github.com/geier/deskscribe
brew install --cask deskscribe
```

Launch DeskScribe, then approve the macOS permission prompts:

- Microphone access for recording.
- Accessibility access for the global hotkey and automatic paste.

The selected speech model downloads automatically the first time it is needed. Models are stored locally under:

```text
~/Library/Application Support/DeskScribe/Models/
```

The app installs as:

```text
/Applications/DeskScribe.app
```

## Features

- Runs speech recognition locally in the macOS app process, without a Python worker.
- Downloads versioned [ONNX](https://onnx.ai/) model packages from Hugging Face on first use.
- Starts and stops dictation with `Option+Space` by default.
- Shows live partial transcription while recording.
- Pastes the final transcript into the previously active app.
- Supports custom hotkeys, trigger mode, model selection, vocabulary replacement rules, transcript history, and launch-at-login.

## Models

DeskScribe currently supports native-compatible NeMo Conformer TDT [ONNX](https://onnx.ai/) packages:

- NVIDIA Parakeet TDT 0.6B v3 Multilingual ONNX: `geier/deskscribe-nvidia-parakeet-tdt-0.6b-v3-onnx` (default)
- DeskScribe PrimeLine ONNX: `geier/deskscribe-parakeet-primeline-onnx`
- NVIDIA Parakeet TDT 0.6B v2 English ONNX: `geier/deskscribe-nvidia-parakeet-tdt-0.6b-v2-onnx`

Each model package is distributed as a ZIP plus manifest and SHA256 checksum. The app verifies the archive before installing it.

## Privacy

DeskScribe records audio only while dictation is active and runs speech recognition locally. Model packages are downloaded on demand from Hugging Face and reused from local storage.

## Documentation

- [Development](docs/DEVELOPMENT.md)
- [Speech Runtime](docs/SPEECH_RUNTIME.md)
- [Model Evaluation](docs/MODEL_EVALUATION.md)
