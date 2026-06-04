import Foundation

enum AppVariant {
    static let githubURL = URL(string: "https://github.com/geier/deskscribe")!
    static let displayName = "DeskScribe ONNX"
    static let logDirectoryName = "DeskScribeONNX"
    static let logFileName = "DeskScribeONNX.log"
    static let supportsPartialTranscription = true
    static let partialTranscriptionInterval = 2.0
    static let partialTranscriptionInitialDelay = 1.4
    static let partialTranscriptionMinimumDuration = 1.0
}
