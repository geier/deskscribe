import Foundation

enum AppVariant {
    static let githubURL = URL(string: "https://github.com/geier/deskscribe")!
    static let displayName = "DeskScribe"
    static let logDirectoryName = "DeskScribe"
    static let logFileName = "DeskScribe.log"
    static let supportsPartialTranscription = true
    static let partialTranscriptionInterval = 2.0
    static let partialTranscriptionInitialDelay = 1.4
    static let partialTranscriptionMinimumDuration = 1.0
}
