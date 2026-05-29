# DeskScribe

DeskScribe is a macOS menu bar dictation app backed by local NeMo ASR.

It is 100% AI slop, including this README, but it works.

## What It Does

- Runs speech recognition locally on your Mac.
- Uses [`primeline/parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline) by default.
- Starts and stops dictation with `Option+Space`.
- Shows live partial transcription while recording.
- Pastes the final transcript into the previously active app.
- Supports custom hotkeys, trigger mode, model repo/file, and vocabulary hints.

The default model is optimized for German ASR and is a 600M parameter NeMo checkpoint. CPU inference on a Mac can be slow, especially on first run.

## macOS App

A development Xcode project lives at:

```bash
macos/ParakeetDictation/ParakeetDictation.xcodeproj
```

Open it with:

```bash
open macos/ParakeetDictation/ParakeetDictation.xcodeproj
```

The app is menu bar-only. It launches `.venv/bin/python asr_worker.py`, talks to the local worker over HTTP, records microphone audio, transcribes it, and pastes the result.

Debug logs are written to:

```bash
~/Library/Logs/DeskScribe/DeskScribe.log
```

Permissions needed:

- Microphone access for recording.
- Accessibility access for the global hotkey event tap and automatic paste.

## Python Setup

Use a virtualenv. On the original development machine this was created with `/opt/homebrew/bin/python3.13`.

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

## Terminal Transcription

The original terminal script still works:

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

## Worker Lookup

The app first looks for a bundled worker at:

```bash
DeskScribe.app/Contents/Resources/Worker
```

Development builds fall back to the repo root from `DeskScribeWorkerRoot` in `Info.plist`. You can override either path at runtime:

```bash
DESKSCRIBE_WORKER_ROOT=/path/to/repo
```

## Releases

Build a zipped app for GitHub Releases:

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

For public distribution, sign with a Developer ID certificate and notarize the zip before attaching it to GitHub Releases. Otherwise, users may need to manually approve the app in macOS Gatekeeper.

## Homebrew

The cask template lives at:

```bash
homebrew/Casks/deskscribe.rb
```

After publishing a release, update the cask version and sha256. It downloads:

```ruby
url "https://github.com/geier/deskscribe/releases/download/v#{version}/DeskScribe-#{version}-macos.zip"
```

Install from a tap with:

```bash
brew tap <owner>/deskscribe
brew install --cask deskscribe
```
