# Future ASR Model Evaluation

DeskScribe currently supports one native ONNX runtime path: `runtime_type=onnxruntime` with `model_type=nemo-conformer-tdt`. Future model work should keep the current Parakeet package stable while evaluating smaller or faster model families behind explicit manifest metadata.

## Recommendation

Investigate Moonshine first. It is designed for low-latency local transcription, has genuinely small model sizes, and already has macOS/Swift and ONNX-oriented integration paths. The lowest-risk first spike is a standalone benchmark using Moonshine or `sherpa-onnx` against DeskScribe WAV fixtures. The lowest-churn production integration is likely a separate runtime adapter selected by manifest metadata, not forcing Moonshine through the current `nemo-conformer-tdt` bridge.

Use WhisperKit/CoreML as the Apple-native comparison track, especially for multilingual dictation quality. Use NeMo CTC models as the first direct-ONNX decoder expansion only if we want to keep all inference inside our existing ONNX Runtime bridge.

## Candidates

- Moonshine Voice streaming models: best smaller/faster candidate. Published numbers claim Tiny Streaming at about 34M parameters and 34ms on MacBook Pro, Small Streaming at about 123M and 73ms, and Medium Streaming at about 245M and 107ms. This is the most promising direction for live dictation latency.
- Moonshine v1 through `sherpa-onnx`: practical first benchmark path with `sherpa-onnx-moonshine-tiny-en-int8` and `sherpa-onnx-moonshine-base-en-int8`. English-only, but tiny/base packages are small and already ONNX-oriented.
- Moonshine v2 through `sherpa-onnx`: language-specific quantized base models for Arabic, Chinese, English, Japanese, Spanish, Ukrainian, Vietnamese, plus tiny variants for English, Japanese, and Korean. No German model was found in the current sherpa-onnx Moonshine list, so this does not replace Parakeet v3 for German dictation yet.
- Moonshine Swift package: likely the cleanest native macOS production path if licensing/package size checks out. This adds a new dependency and runtime adapter, but avoids hand-maintaining model-specific decoders.
- WhisperKit/CoreML: Apple-native baseline with automatic model downloads and tiny/base model options. Good comparison target for quality and packaging, but Whisper's 30-second window and seq2seq decoding make it less attractive for very low latency than Moonshine.
- sherpa-onnx Zipformer CTC or transducer models: practical local ASR stack with prebuilt ONNX models; CTC variants are simpler to decode than TDT/RNNT. Useful if Moonshine quality is insufficient or language coverage matters.
- NeMo CTC models, including `sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8`: closest to the existing NeMo/export ecosystem and a plausible direct-ONNX bridge expansion. English-only for the 110M model found during research.
- Quantized Parakeet-style variants: useful optimization track, but not a true smaller-family solution if model scale remains near 0.6B.

## Runtime Implications

- `sherpa-onnx` support probably needs a separate runtime adapter instead of forcing those models through the current `NativeONNXBridge`.
- CTC support needs different output-shape handling plus CTC blank-collapse decoding, but can reuse much of the current ONNX Runtime package/load infrastructure.
- Whisper support needs Whisper-specific 80-bin log-mel preprocessing, chunking, special token handling, language/task controls, and seq2seq decoding.
- CoreML or MLX support should be treated as separate runtime types, not as variants of the current ONNX Runtime bridge.

The current app validates downloaded packages as `runtime_type=onnxruntime` and `model_type=nemo-conformer-tdt`. Any smaller/faster model family should therefore start behind new manifest values, for example `runtime_type=moonshine`, `runtime_type=sherpa-onnx`, `runtime_type=coreml`, or `model_type=nemo-ctc`. This avoids weakening validation for the existing Parakeet packages.

## Adaptation Paths

### Moonshine Swift Adapter

- Add Moonshine's Swift package or vendored native library as an app dependency.
- Add a new `TranscriptionRuntime` implementation that feeds DeskScribe's recorded mono audio into Moonshine and returns the final transcript text.
- Package Moonshine model files with our existing download/install/manifest flow, but dispatch by a new runtime/model type.
- Benchmark Tiny/Small/Medium against DeskScribe fixtures and real dictation clips before exposing the option in Preferences.

This is the best candidate for a production-quality smaller/faster option if English-only or language-specific coverage is acceptable.

### sherpa-onnx Adapter

- Build or vendor `sherpa-onnx` for macOS and call its C/Swift API from a separate runtime adapter.
- Start with `sherpa-onnx-moonshine-tiny-en-int8` and `sherpa-onnx-moonshine-base-en-int8` because they are small and already documented.
- Reuse our package download flow, but preserve sherpa's expected model file layout and config.

This is probably faster to benchmark than a hand-written decoder, but it introduces another native runtime library alongside ONNX Runtime.

### Direct ONNX CTC Adapter

- Add a new `model_type=nemo-ctc` or `model_type=onnx-ctc` path in our current ONNX Runtime bridge.
- Implement CTC output handling and greedy blank-collapse decoding.
- Try NeMo CTC exports and the 110M Parakeet CTC package first.

This keeps the dependency story simple, but it only helps models whose preprocessing and tokenizer are close enough to implement cleanly in our code.

## CoreML And MLX

Do not prioritize a full CoreML or MLX production runtime yet. CoreML is the better fit for a signed native macOS app because it is a system framework and Swift-friendly, but the practical ASR path is likely WhisperKit/CoreML rather than a custom CoreML conversion for every model family. MLX is useful for Apple Silicon research and benchmarking, especially for Whisper or Parakeet-family experiments, but it is less turnkey as an embedded app runtime because packaging and native integration are still more complex than CoreML or ONNX Runtime.

The first Apple-specific spike should be WhisperKit/CoreML on the shared DeskScribe WAV fixtures, measuring startup time, package size, memory, latency, and dictation quality. MLX should stay a research harness unless it clearly unlocks model quality or performance that ONNX/CoreML cannot match.

## Manifest Implications

Future manifests should continue using `runtime_type` and `model_type` as the dispatch boundary. Package metadata should describe required model files by role, preprocessing parameters, tokenizer details, decoding strategy, quantization, expected memory/runtime characteristics, and source/license metadata.

## Next Investigation

1. Build a standalone Moonshine benchmark on DeskScribe fixtures, starting with Tiny/Small or `sherpa-onnx-moonshine-tiny-en-int8` and `sherpa-onnx-moonshine-base-en-int8`.
2. Record or add at least 5 short real dictation fixtures covering English and German, since Moonshine's immediate path may not cover German.
3. Compare WhisperKit tiny/base against the same fixtures for Apple-native quality and packaging baseline.
4. If native ORT-only support remains a priority, prototype CTC package validation plus greedy CTC decoding with a NeMo CTC model before tackling Whisper or another transducer/RNNT variant.
