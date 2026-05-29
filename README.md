# DeskScribe

DeskScribe is a macOS menu bar dictation app backed by local NeMo ASR. The terminal script runs [`primeline/parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline) locally, records microphone audio in short chunks, and prints each transcription to the terminal.

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

The app is a menu bar-only AppKit app. It launches `.venv/bin/python asr_worker.py`, uses `Option+Space` as the default global hotkey, records in toggle mode by default, sends the final WAV to the worker, then pastes the final transcript into the previously active app.

Use the menu bar Preferences item to change the hotkey or model repo/file. Changing the model restarts the worker so the selected Hugging Face `.nemo` file can be downloaded/loaded.

Debug logs are written to `~/Library/Logs/DeskScribe/DeskScribe.log` and can be opened from the menu bar item.

Development notes:

```bash
open macos/ParakeetDictation/ParakeetDictation.xcodeproj
```

The app first looks for a bundled worker at `DeskScribe.app/Contents/Resources/Worker`. Development builds fall back to the repo root from `DeskScribeWorkerRoot` in `Info.plist`. You can override either path at runtime with `DESKSCRIBE_WORKER_ROOT=/path/to/repo`.

macOS permissions needed:

- Microphone access for recording.
- Accessibility access for the global hotkey event tap and automatic paste.

## GitHub Releases and Homebrew

The Homebrew path is a cask that downloads a zipped `.app` from GitHub Releases. The release `.app` bundles the Python worker and virtualenv under `Contents/Resources/Worker`, so it does not depend on this repo or a local `.venv` path after installation.

Build a release artifact:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  scripts/build_release.sh 0.1.0
```

For local testing without Developer ID signing, the script defaults to ad-hoc signing:

```bash
scripts/build_release.sh 0.1.0
```

The script writes:

```bash
dist/DeskScribe-0.1.0-macos.zip
dist/DeskScribe-0.1.0-macos.zip.sha256
```

Publish the zip to a GitHub Release named `v0.1.0`, then update `homebrew/Casks/deskscribe.rb`:

```ruby
version "0.1.0"
sha256 "<sha256 from dist/*.sha256>"
url "https://github.com/geier/deskscribe/releases/download/v#{version}/DeskScribe-#{version}-macos.zip"
homepage "https://github.com/geier/deskscribe"
```

For a private tap, copy the cask into a repo named like `homebrew-deskscribe` under `Casks/deskscribe.rb`. Users can then install with:

```bash
brew tap <owner>/deskscribe
brew install --cask deskscribe
```

For public distribution, sign with a Developer ID certificate and notarize the zip before attaching it to GitHub Releases. Otherwise, users may need to manually approve the app in macOS Gatekeeper.
