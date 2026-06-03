---
license: cc-by-4.0
base_model:
- primeline/parakeet-primeline
- nvidia/parakeet-tdt-0.6b-v3
library_name: onnxruntime
tags:
- automatic-speech-recognition
- onnx
- deskscribe
- parakeet
---

# DeskScribe Parakeet PrimeLine ONNX

This repository hosts an unofficial ONNX export of [`primeline/parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline) for the native DeskScribe macOS app.

The original model is based on [`nvidia/parakeet-tdt-0.6b-v3`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). Both source repositories declare [`cc-by-4.0`](https://creativecommons.org/licenses/by/4.0/) on Hugging Face.

## Files

- `parakeet-primeline-onnx-v1.zip`: ONNX Runtime model package for DeskScribe.
- `parakeet-primeline-onnx-v1.manifest.json`: package metadata used by the app downloader.
- `parakeet-primeline-onnx-v1.zip.sha256`: archive checksum.

## Attribution

- Original fine-tuned model: [`primeline/parakeet-primeline`](https://huggingface.co/primeline/parakeet-primeline)
- Base model: [`nvidia/parakeet-tdt-0.6b-v3`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- License: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)

## Notes

This conversion is not an official primeLine or NVIDIA release and does not imply endorsement by the original authors. The package is intended for DeskScribe's native ONNX runtime.
