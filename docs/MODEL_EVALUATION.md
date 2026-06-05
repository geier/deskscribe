# Future ASR Model Evaluation

DeskScribe currently supports one native ONNX runtime path: `runtime_type=onnxruntime` with `model_type=nemo-conformer-tdt`. Future model work should keep the current Parakeet package stable while evaluating smaller or faster model families behind explicit manifest metadata.

## Recommendation

Investigate Moonshine via `sherpa-onnx` first. It is designed for low-latency local transcription, has small model sizes, and avoids immediately hand-writing another native decoder. Use Whisper tiny/base or Distil-Whisper as a quality comparison track, and use CTC models as the first direct-ONNX native decoder expansion if we want to stay close to the current ORT bridge.

## Candidates

- Moonshine tiny/base through `sherpa-onnx`: best first speed/package-size candidate; requires a new runtime adapter and model package type.
- sherpa-onnx Zipformer CTC or transducer models: practical local ASR stack with prebuilt ONNX models; CTC variants are simpler to decode than TDT/RNNT.
- Whisper tiny/base/small or Distil-Whisper: strong ecosystem and dictation quality, but preprocessing/decoding differs substantially from the current Nemo path.
- NeMo FastConformer CTC: closest to the existing export ecosystem and likely the smallest native decoder change if compatible checkpoints export cleanly.
- Quantized Parakeet-style variants: useful optimization track, but not a true smaller-family solution if model scale remains near 0.6B.

## Runtime Implications

- `sherpa-onnx` support probably needs a separate runtime adapter instead of forcing those models through the current `NativeONNXBridge`.
- CTC support needs different output-shape handling plus CTC blank-collapse decoding, but can reuse much of the current ONNX Runtime package/load infrastructure.
- Whisper support needs Whisper-specific 80-bin log-mel preprocessing, chunking, special token handling, language/task controls, and seq2seq decoding.
- CoreML or MLX support should be treated as separate runtime types, not as variants of the current ONNX Runtime bridge.

## CoreML And MLX

Do not prioritize a full CoreML or MLX production runtime yet. CoreML is the better fit for a signed native macOS app because it is a system framework and Swift-friendly, but the practical ASR path is likely WhisperKit/CoreML rather than a custom CoreML conversion for every model family. MLX is useful for Apple Silicon research and benchmarking, especially for Whisper or Parakeet-family experiments, but it is less turnkey as an embedded app runtime because packaging and native integration are still more complex than CoreML or ONNX Runtime.

The first Apple-specific spike should be WhisperKit/CoreML on the shared DeskScribe WAV fixtures, measuring startup time, package size, memory, latency, and dictation quality. MLX should stay a research harness unless it clearly unlocks model quality or performance that ONNX/CoreML cannot match.

## Manifest Implications

Future manifests should continue using `runtime_type` and `model_type` as the dispatch boundary. Package metadata should describe required model files by role, preprocessing parameters, tokenizer details, decoding strategy, quantization, expected memory/runtime characteristics, and source/license metadata.

## Next Investigation

1. Benchmark Moonshine tiny/base through `sherpa-onnx` on DeskScribe WAV fixtures.
2. Compare Whisper tiny/base or Distil-Whisper against the same fixtures through an existing mature runtime.
3. Run a standalone WhisperKit/CoreML spike on the shared fixtures before committing to a CoreML production runtime.
4. If native ORT-only support remains a priority, prototype a CTC model package and greedy CTC decoder before tackling Whisper or another transducer/RNNT variant.
