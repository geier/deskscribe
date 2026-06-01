import Foundation

enum AppVariant {
    static let githubURL = URL(string: "https://github.com/geier/deskscribe")!

#if DESKSCRIBE_NATIVE_ONNX
    static let displayName = "DeskScribe ONNX"
    static let logDirectoryName = "DeskScribeONNX"
    static let logFileName = "DeskScribeONNX.log"
    static let workerPort = 8766
    static let workerScriptName = "asr_worker_onnx.py"

    static func workerArguments(host: String, port: Int, model: ModelSettings) -> [String] {
        [
            "--host", host,
            "--port", String(port),
            "--model-dir", "models/parakeet-primeline-onnx",
            "--debug"
        ]
    }
#else
    static let displayName = "DeskScribe"
    static let logDirectoryName = "DeskScribe"
    static let logFileName = "DeskScribe.log"
    static let workerPort = 8765
    static let workerScriptName = "asr_worker.py"

    static func workerArguments(host: String, port: Int, model: ModelSettings) -> [String] {
        [
            "--host", host,
            "--port", String(port),
            "--model-repo", model.repo,
            "--model-file", model.file,
            "--debug"
        ]
    }
#endif
}
