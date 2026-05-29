import Foundation

enum WorkerState {
    case loading
    case ready
    case failed(String)
}

final class WorkerManager {
    private let repoRoot: URL
    private var model: ModelSettings
    private let host = "127.0.0.1"
    private let port = 8765
    private var process: Process?
    private var outputPipe: Pipe?
    private var pollTimer: Timer?

    var onStateChange: ((WorkerState) -> Void)?
    private(set) var isReady = false

    private var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    init(repoRoot: URL, model: ModelSettings) {
        self.repoRoot = repoRoot
        self.model = model
    }

    func updateModel(_ model: ModelSettings) {
        guard self.model != model else { return }
        DebugLog.shared.info("worker model updated repo=\(model.repo) file=\(model.file)")
        self.model = model
        restart()
    }

    func start() {
        DebugLog.shared.info("worker manager start")
        isReady = false
        onStateChange?(.loading)
        launchProcess()
        startPolling()
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        DebugLog.shared.info("worker manager stop")
        pollTimer?.invalidate()
        pollTimer = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        isReady = false
    }

    func transcribe(audioURL: URL, vocabulary: VocabularySettings, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let audioData = try Data(contentsOf: audioURL)
            DebugLog.shared.info("transcribe request audio bytes=\(audioData.count) vocabulary=\(vocabulary.words.count)")
            let boundary = "Boundary-\(UUID().uuidString)"
            var body = Data()
            let vocabularyJSON = try JSONEncoder().encode(vocabulary.words)
            let vocabularyText = String(data: vocabularyJSON, encoding: .utf8) ?? "[]"
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"vocabulary\"\r\n\r\n")
            body.appendString(vocabularyText)
            body.appendString("\r\n")
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
            body.appendString("Content-Type: audio/wav\r\n\r\n")
            body.append(audioData)
            body.appendString("\r\n--\(boundary)--\r\n")

            var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    DebugLog.shared.error("transcribe request failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode), let data else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    DebugLog.shared.error("transcribe bad response status=\(status), bytes=\(data?.count ?? 0)")
                    completion(.failure(WorkerError.badResponse))
                    return
                }

                DebugLog.shared.info("transcribe response status=\(httpResponse.statusCode), bytes=\(data.count)")

                do {
                    let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
                    completion(.success(decoded.text))
                } catch {
                    DebugLog.shared.error("transcribe JSON decode failed: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }.resume()
        } catch {
            DebugLog.shared.error("failed reading audio for transcription: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }

    private func launchProcess() {
        let pythonURL = repoRoot.appendingPathComponent(".venv/bin/python")
        let workerURL = repoRoot.appendingPathComponent("asr_worker.py")

        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            DebugLog.shared.error("missing python executable at \(pythonURL.path)")
            onStateChange?(.failed("missing .venv/bin/python"))
            return
        }
        guard FileManager.default.fileExists(atPath: workerURL.path) else {
            DebugLog.shared.error("missing worker at \(workerURL.path)")
            onStateChange?(.failed("missing asr_worker.py"))
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                DebugLog.shared.info("worker output: \(line)")
            }
        }

        DebugLog.shared.info("launching worker: \(pythonURL.path) \(workerURL.path) --host \(host) --port \(port) --model-repo \(model.repo) --model-file \(model.file)")
        process.executableURL = pythonURL
        process.arguments = [
            workerURL.path,
            "--host", host,
            "--port", String(port),
            "--model-repo", model.repo,
            "--model-file", model.file,
            "--debug"
        ]
        process.currentDirectoryURL = repoRoot
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, !self.isReady else { return }
                DebugLog.shared.error("worker exited with status \(process.terminationStatus)")
                self.onStateChange?(.failed("worker exited with status \(process.terminationStatus)"))
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            DebugLog.shared.info("worker process launched pid=\(process.processIdentifier)")
        } catch {
            DebugLog.shared.error("worker launch failed: \(error.localizedDescription)")
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        checkHealth()
    }

    private func checkHealth() {
        URLSession.shared.dataTask(with: baseURL.appendingPathComponent("health")) { [weak self] _, response, _ in
            guard let self else { return }
            let healthy = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async {
                if healthy && !self.isReady {
                    self.isReady = true
                    DebugLog.shared.info("worker health check passed")
                    self.onStateChange?(.ready)
                } else if !healthy && self.process?.isRunning == true && !self.isReady {
                    DebugLog.shared.info("worker health check waiting")
                    self.onStateChange?(.loading)
                }
            }
        }.resume()
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private enum WorkerError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "ASR worker returned an unexpected response"
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(value.data(using: .utf8)!)
    }
}
