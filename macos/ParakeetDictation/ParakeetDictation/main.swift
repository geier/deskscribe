import AppKit
import Foundation

#if DESKSCRIBE_NATIVE_ONNX
private struct NativeONNXSmokeTestResult: Encodable {
    let path: String
    let text: String?
    let error: String?
}

private func runNativeONNXSmokeTest(arguments: [String]) -> Int32 {
    var audioPaths: [String] = []
    var repoRoot: URL?
    var index = 0

    while index < arguments.count {
        switch arguments[index] {
        case "--native-onnx-smoke-test":
            index += 1
            guard index < arguments.count else {
                fputs("Missing path after --native-onnx-smoke-test\n", stderr)
                return 2
            }
            audioPaths.append(arguments[index])
        case "--repo-root":
            index += 1
            guard index < arguments.count else {
                fputs("Missing path after --repo-root\n", stderr)
                return 2
            }
            repoRoot = URL(fileURLWithPath: arguments[index]).standardizedFileURL
        default:
            fputs("Unknown smoke-test argument: \(arguments[index])\n", stderr)
            return 2
        }
        index += 1
    }

    guard !audioPaths.isEmpty else {
        fputs("Pass at least one --native-onnx-smoke-test WAV path.\n", stderr)
        return 2
    }

    let runtime = NativeONNXRuntime(repoRoot: repoRoot)
    let readySemaphore = DispatchSemaphore(value: 0)
    var startupError: String?

    runtime.onProgress = { message in
        fputs("native-onnx: \(message)\n", stderr)
    }
    runtime.onStateChange = { state in
        switch state {
        case .ready:
            readySemaphore.signal()
        case .failed(let message):
            startupError = message
            readySemaphore.signal()
        case .loading:
            break
        }
    }
    runtime.start()

    if readySemaphore.wait(timeout: .now() + 3600) == .timedOut {
        fputs("Native ONNX runtime did not become ready within 3600 seconds.\n", stderr)
        return 1
    }
    if let startupError {
        fputs("Native ONNX runtime failed: \(startupError)\n", stderr)
        return 1
    }

    var results: [NativeONNXSmokeTestResult] = []
    for path in audioPaths {
        let audioURL = URL(fileURLWithPath: path).standardizedFileURL
        let transcriptionSemaphore = DispatchSemaphore(value: 0)
        var transcriptionResult: Result<String, Error>?

        runtime.transcribe(audioURL: audioURL, vocabulary: AppSettings.defaultVocabulary, priority: .final) { result in
            transcriptionResult = result
            transcriptionSemaphore.signal()
        }
        transcriptionSemaphore.wait()

        switch transcriptionResult {
        case .success(let text):
            results.append(NativeONNXSmokeTestResult(path: audioURL.path, text: text, error: nil))
        case .failure(let error):
            results.append(NativeONNXSmokeTestResult(path: audioURL.path, text: nil, error: error.localizedDescription))
        case .none:
            results.append(NativeONNXSmokeTestResult(path: audioURL.path, text: nil, error: "transcription did not return a result"))
        }
    }

    runtime.stop()

    do {
        let data = try JSONEncoder().encode(["fixtures": results])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fputs("Could not encode smoke-test results: \(error.localizedDescription)\n", stderr)
        return 1
    }

    return results.contains { $0.error != nil } ? 1 : 0
}
#endif

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--native-onnx-smoke-test") {
#if DESKSCRIBE_NATIVE_ONNX
    exit(runNativeONNXSmokeTest(arguments: arguments))
#else
    fputs("--native-onnx-smoke-test is only available in the native ONNX build.\n", stderr)
    exit(2)
#endif
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
