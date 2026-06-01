import Foundation

final class DebugLog {
    static let shared = DebugLog()

    let url: URL
    private let queue = DispatchQueue(label: "DeskScribe.DebugLog")
    private let formatter = ISO8601DateFormatter()

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(AppVariant.logDirectoryName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(AppVariant.logFileName)
        info("--- app session started ---")
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func warning(_ message: String) {
        write(level: "WARN", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(level)] \(message)\n"

        queue.async { [url] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    NSLog("\(AppVariant.displayName) log write failed: \(error.localizedDescription)")
                }
            } else {
                try? data.write(to: url)
            }
        }

        NSLog("\(AppVariant.displayName) [\(level)] \(message)")
    }
}
