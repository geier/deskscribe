# Local Microphone Transcription

This runs [`primeline/parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline) locally on macOS, records microphone audio in short chunks, and prints each transcription to the terminal.

The model is optimized for German ASR and is a 600M parameter NeMo checkpoint. CPU inference on a Mac can be slow, especially on first run.

## Setup

Use Python 3.11 if possible. The current machine has Python 3.11 available.

```bash
python3 -m venv .venv
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
```

`--device mps` is available, but `--device cpu` is the safest default for NeMo on macOS.
