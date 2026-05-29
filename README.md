# Local Microphone Transcription

This runs [`primeline/parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline) locally on macOS, records microphone audio in short chunks, and prints each transcription to the terminal.

The model is optimized for German ASR and is a 600M parameter NeMo checkpoint. CPU inference on a Mac can be slow, especially on first run.

## Setup

Use the project virtualenv. On this machine it was created with `/opt/homebrew/bin/python3.13`.

```bash
/opt/homebrew/bin/python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
pip install -r requirements.txt
```

If `sounddevice` cannot find PortAudio, install it with Homebrew and reinstall `sounddevice`:

```bash
brew install portaudio
pip install --force-reinstall sounddevice
```

macOS may ask for Terminal microphone permission the first time this runs. If recording fails, enable microphone access for your terminal app in `System Settings > Privacy & Security > Microphone`.

## Run

```bash
source .venv/bin/activate
python transcribe_mic.py
```

Useful options:

```bash
python transcribe_mic.py --chunk-seconds 8
python transcribe_mic.py --list-devices
python transcribe_mic.py --input-device 0
python transcribe_mic.py --min-rms 0
python transcribe_mic.py --verbose
```

`--device mps` is available, but `--device cpu` is the safest default for NeMo on macOS.

## HTTP Worker

The macOS app uses a long-running local worker so the NeMo model loads once:

```bash
source .venv/bin/activate
python asr_worker.py
```

Endpoints:

```bash
GET http://127.0.0.1:8765/health
POST http://127.0.0.1:8765/transcribe
```

`POST /transcribe` accepts a multipart WAV upload named `file` and returns JSON like `{ "text": "..." }`.

## macOS App

A development Xcode project lives at `macos/ParakeetDictation/ParakeetDictation.xcodeproj`.

The app is a menu bar-only AppKit app. It launches `.venv/bin/python asr_worker.py`, uses `Option+Space` as a press-and-hold global hotkey, records while held, sends the final WAV to the worker, then pastes the final transcript into the previously active app.

Use the menu bar Preferences item to change the hotkey or model repo/file. Changing the model restarts the worker so the selected Hugging Face `.nemo` file can be downloaded/loaded.

Debug logs are written to `~/Library/Logs/ParakeetDictation/ParakeetDictation.log` and can be opened from the menu bar item.

Development notes:

```bash
open macos/ParakeetDictation/ParakeetDictation.xcodeproj
```

The app expects the repo root from its built `ParakeetRepoRoot` Info.plist value. You can override that at runtime with `PARAKEET_REPO_ROOT=/path/to/repo`.

macOS permissions needed:

- Microphone access for recording.
- Accessibility access for the global hotkey event tap and automatic paste.
