import Accelerate
import CryptoKit
import Foundation

enum WorkerState {
    case loading
    case ready
    case failed(String)
}

protocol TranscriptionRuntime: AnyObject {
    var onStateChange: ((WorkerState) -> Void)? { get set }
    var onProgress: ((String) -> Void)? { get set }
    var isReady: Bool { get }

    func start()
    func restart()
    func stop()
    func updateModel(_ model: ModelSettings)
    func cancelPendingTranscriptions()
    func transcribe(audioURL: URL, vocabulary: VocabularySettings, completion: @escaping (Result<String, Error>) -> Void)
    func transcribe(audioURL: URL, vocabulary: VocabularySettings, priority: TranscriptionPriority, completion: @escaping (Result<String, Error>) -> Void)
    func transcribe(samples: [Float], vocabulary: VocabularySettings, priority: TranscriptionPriority, completion: @escaping (Result<String, Error>) -> Void)
}

enum TranscriptionPriority {
    case partialPreview
    case final
}

extension TranscriptionRuntime {
    func cancelPendingTranscriptions() {}

    func transcribe(audioURL: URL, vocabulary: VocabularySettings, priority: TranscriptionPriority, completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(audioURL: audioURL, vocabulary: vocabulary, completion: completion)
    }

    func transcribe(samples: [Float], vocabulary: VocabularySettings, priority: TranscriptionPriority, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(NativeONNXRuntimeError.notImplemented))
    }
}

enum TranscriptionRuntimeFactory {
    static func make(repoRoot: URL?, model: ModelSettings) -> TranscriptionRuntime {
        NativeONNXRuntime(repoRoot: repoRoot, model: model)
    }
}

struct NativeONNXModelPackage {
    let preset: NativeONNXModelPreset
    let directory: URL

    static func defaultInstalledDirectory(for preset: NativeONNXModelPreset) -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskScribe", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        return baseDirectory.appendingPathComponent("\(preset.id)-\(preset.version)", isDirectory: true)
    }

    static func developmentDirectory(repoRoot: URL, for preset: NativeONNXModelPreset) -> URL {
        repoRoot.appendingPathComponent("models/\(preset.id)", isDirectory: true)
    }

    static func resolve(repoRoot: URL?, model: ModelSettings) -> NativeONNXModelPackage {
        let preset = NativeONNXModelPresets.preset(for: model)
        let candidates = [defaultInstalledDirectory(for: preset)] + (repoRoot.map { [developmentDirectory(repoRoot: $0, for: preset)] } ?? [])
        for directory in candidates {
            let package = NativeONNXModelPackage(preset: preset, directory: directory)
            do {
                try package.validate()
                DebugLog.shared.info("using native ONNX model package at \(directory.path)")
                return package
            } catch {
                DebugLog.shared.warning("native ONNX model candidate invalid path=\(directory.path): \(error.localizedDescription)")
            }
        }

        return NativeONNXModelPackage(preset: preset, directory: defaultInstalledDirectory(for: preset))
    }

    private static let requiredFiles = [
        "encoder-model.onnx",
        "decoder_joint-model.onnx",
        "vocab.txt",
        "config.json",
        "mel_fbanks_nemo128.bin",
        "MODEL_LICENSE.md"
    ]

    func validate() throws {
        let missing = Self.requiredFiles.filter { name in
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        guard missing.isEmpty else {
            throw NativeONNXRuntimeError.missingModelFiles(directory.path, missing)
        }
    }
}

private struct NativeONNXModelManifest: Decodable {
    let id: String
    let version: String
    let runtimeType: String
    let modelType: String
    let archive: String
    let archiveURL: URL?
    let sha256: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case runtimeType = "runtime_type"
        case modelType = "model_type"
        case archive
        case archiveURL = "archive_url"
        case sha256
        case size
    }
}

private enum NativeONNXModelDownloadError: LocalizedError {
    case missingArchiveURL
    case unexpectedManifest(String, String)
    case unsupportedManifest(runtimeType: String, modelType: String)
    case badHTTPStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case unzipFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingArchiveURL:
            return "model manifest is missing archive_url"
        case .unexpectedManifest(let id, let version):
            return "model manifest describes unexpected package \(id)-\(version)"
        case .unsupportedManifest(let runtimeType, let modelType):
            return "model manifest describes unsupported runtime=\(runtimeType) model=\(modelType)"
        case .badHTTPStatus(let status):
            return "model download failed with HTTP status \(status)"
        case .checksumMismatch(let expected, let actual):
            return "model checksum mismatch expected=\(expected) actual=\(actual)"
        case .unzipFailed(let status):
            return "model unzip failed with status \(status)"
        }
    }
}

private final class NativeONNXModelDownloader: NSObject, URLSessionDownloadDelegate {
    private let manifestURL: URL
    private let destinationPackage: NativeONNXModelPackage
    private let progress: (String) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var manifest: NativeONNXModelManifest?
    private var lastReportedDownloadPercent: Int?

    init(
        manifestURL: URL,
        destinationPackage: NativeONNXModelPackage,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.manifestURL = manifestURL
        self.destinationPackage = destinationPackage
        self.progress = progress
        self.completion = completion
    }

    func start() {
        progress("Fetching model manifest...")
        URLSession.shared.dataTask(with: manifestURL) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.completion(.failure(error))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                self.completion(.failure(NativeONNXModelDownloadError.badHTTPStatus(httpResponse.statusCode)))
                return
            }
            guard let data else {
                self.completion(.failure(NativeONNXModelDownloadError.badHTTPStatus(-1)))
                return
            }

            do {
                let manifest = try JSONDecoder().decode(NativeONNXModelManifest.self, from: data)
                guard manifest.id == self.destinationPackage.preset.id, manifest.version == self.destinationPackage.preset.version else {
                    throw NativeONNXModelDownloadError.unexpectedManifest(manifest.id, manifest.version)
                }
                guard manifest.runtimeType == "onnxruntime", manifest.modelType == "nemo-conformer-tdt" else {
                    throw NativeONNXModelDownloadError.unsupportedManifest(runtimeType: manifest.runtimeType, modelType: manifest.modelType)
                }
                guard manifest.archiveURL != nil else {
                    throw NativeONNXModelDownloadError.missingArchiveURL
                }
                self.manifest = manifest
                self.downloadArchive(manifest)
            } catch {
                self.completion(.failure(error))
            }
        }.resume()
    }

    private func downloadArchive(_ manifest: NativeONNXModelManifest) {
        guard let archiveURL = manifest.archiveURL else {
            completion(.failure(NativeONNXModelDownloadError.missingArchiveURL))
            return
        }

        progress("Downloading model...")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: archiveURL).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let manifest else {
            completion(.failure(NativeONNXModelDownloadError.missingArchiveURL))
            return
        }

        do {
            progress("Verifying model...")
            let actualSHA256 = try Self.sha256Hex(for: location)
            guard actualSHA256.lowercased() == manifest.sha256.lowercased() else {
                throw NativeONNXModelDownloadError.checksumMismatch(expected: manifest.sha256, actual: actualSHA256)
            }

            progress("Installing model...")
            try installArchive(location)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100)
        guard percent == 100 || percent % 5 == 0 else { return }
        guard lastReportedDownloadPercent != percent else { return }
        lastReportedDownloadPercent = percent
        progress("Downloading model... \(percent)%")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(.failure(error))
        }
        session.invalidateAndCancel()
    }

    private func installArchive(_ archiveURL: URL) throws {
        let fileManager = FileManager.default
        let destination = destinationPackage.directory
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(".\(destinationPackage.preset.id)-\(destinationPackage.preset.version)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try Self.unzip(archiveURL, to: staging)
        try NativeONNXModelPackage(preset: destinationPackage.preset, directory: staging).validate()

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func unzip(_ archiveURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeONNXModelDownloadError.unzipFailed(process.terminationStatus)
        }
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class NativeONNXRuntime: TranscriptionRuntime {
    private var modelPackage: NativeONNXModelPackage
    private let transcriptionQueue = DispatchQueue(label: "local.DeskScribe.NativeONNXRuntime.transcription", qos: .userInitiated)
    private let modelLoadQueue = DispatchQueue(label: "local.DeskScribe.NativeONNXRuntime.model-load", qos: .userInitiated)
    private var modelDownloader: NativeONNXModelDownloader?
    private var bridge: NativeONNXBridge?
    private var vocabulary: NativeONNXVocabulary?
    private var preprocessor: NativeONNXPreprocessor?
    private let cancellationLock = NSLock()
    private var cancellationGeneration = 0

    var onStateChange: ((WorkerState) -> Void)?
    var onProgress: ((String) -> Void)?
    private(set) var isReady = false

    private let repoRoot: URL?

    init(repoRoot: URL, model: ModelSettings) {
        self.repoRoot = repoRoot
        modelPackage = NativeONNXModelPackage.resolve(repoRoot: repoRoot, model: model)
    }

    init(repoRoot: URL?, model: ModelSettings) {
        self.repoRoot = repoRoot
        modelPackage = NativeONNXModelPackage.resolve(repoRoot: repoRoot, model: model)
    }

    func start() {
        isReady = false
        onStateChange?(.loading)

        modelLoadQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.modelPackage.validate()
                try self.loadModelPackage()
            } catch {
                self.downloadAndLoadModel()
            }
        }
    }

    private func loadModelPackage() throws {
        try modelPackage.validate()
        bridge = try NativeONNXBridge(modelDirectory: modelPackage.directory)
        vocabulary = try NativeONNXVocabulary(url: modelPackage.directory.appendingPathComponent("vocab.txt"))
        preprocessor = try NativeONNXPreprocessor(modelDirectory: modelPackage.directory)
        isReady = true
        DebugLog.shared.info(
            "native ONNX sessions loaded encoderInputs=\(bridge?.encoderInputNames ?? []) encoderOutputs=\(bridge?.encoderOutputNames ?? []) decoderInputs=\(bridge?.decoderInputNames ?? []) decoderOutputs=\(bridge?.decoderOutputNames ?? []) vocabSize=\(vocabulary?.tokens.count ?? 0) blankID=\(vocabulary?.blankID ?? -1)"
        )
        onStateChange?(.ready)
    }

    private func downloadAndLoadModel() {
        let installedPackage = NativeONNXModelPackage(
            preset: modelPackage.preset,
            directory: NativeONNXModelPackage.defaultInstalledDirectory(for: modelPackage.preset)
        )
        DebugLog.shared.info("native ONNX model package missing; downloading from \(modelPackage.preset.manifestURL.absoluteString)")
        onProgress?("Downloading model...")

        let downloader = NativeONNXModelDownloader(
            manifestURL: modelPackage.preset.manifestURL,
            destinationPackage: installedPackage,
            progress: { [weak self] message in
                DebugLog.shared.info("model download progress: \(message)")
                self?.onProgress?(message)
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.modelDownloader = nil
                    switch result {
                    case .success:
                        DebugLog.shared.info("native ONNX model package downloaded")
                        self.modelLoadQueue.async {
                            do {
                                try self.loadModelPackage()
                            } catch {
                                self.onStateChange?(.failed(error.localizedDescription))
                            }
                        }
                    case .failure(let error):
                        DebugLog.shared.error("native ONNX model download failed: \(error.localizedDescription)")
                        self.onStateChange?(.failed(error.localizedDescription))
                    }
                }
            }
        )
        modelDownloader = downloader
        downloader.start()
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        cancelPendingTranscriptions()
        modelDownloader = nil
        bridge = nil
        vocabulary = nil
        preprocessor = nil
        isReady = false
    }

    func updateModel(_ model: ModelSettings) {
        modelPackage = NativeONNXModelPackage.resolve(repoRoot: repoRoot, model: model)
        restart()
    }

    func cancelPendingTranscriptions() {
        cancellationLock.lock()
        cancellationGeneration += 1
        cancellationLock.unlock()
    }

    func transcribe(audioURL: URL, vocabulary: VocabularySettings, completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(audioURL: audioURL, vocabulary: vocabulary, priority: .final, completion: completion)
    }

    func transcribe(audioURL: URL, vocabulary: VocabularySettings, priority: TranscriptionPriority, completion: @escaping (Result<String, Error>) -> Void) {
        guard let bridge, let nativeVocabulary = self.vocabulary, let preprocessor else {
            completion(.failure(NativeONNXRuntimeError.notReady))
            return
        }

        let requestGeneration = currentCancellationGeneration()

        transcriptionQueue.async {
            do {
                try self.checkCancellation(priority: priority, generation: requestGeneration)
                let startedAt = Date()
                self.onProgress?("Loading audio...")
                let audio = try NativeONNXWAVAudio(url: audioURL)
                DebugLog.shared.info("native ONNX audio loaded sampleRate=\(audio.sampleRate) samples=\(audio.samples.count) rms=\(String(format: "%.5f", audio.rms)) peak=\(String(format: "%.5f", audio.peak))")
                try self.checkCancellation(priority: priority, generation: requestGeneration)
                let audioLoadedAt = Date()
                let text = try self.transcribeLoadedSamples(
                    audio.samples,
                    vocabulary: vocabulary,
                    nativeVocabulary: nativeVocabulary,
                    preprocessor: preprocessor,
                    bridge: bridge,
                    priority: priority,
                    generation: requestGeneration,
                    startedAt: startedAt,
                    audioLoadedAt: audioLoadedAt
                )
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.preserveEmptyTranscriptAudio(audioURL)
                }
                completion(.success(text))
            } catch {
                DebugLog.shared.error("native ONNX transcription failed: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    func transcribe(samples: [Float], vocabulary: VocabularySettings, priority: TranscriptionPriority, completion: @escaping (Result<String, Error>) -> Void) {
        guard let bridge, let nativeVocabulary = self.vocabulary, let preprocessor else {
            completion(.failure(NativeONNXRuntimeError.notReady))
            return
        }

        let requestGeneration = currentCancellationGeneration()

        transcriptionQueue.async {
            do {
                try self.checkCancellation(priority: priority, generation: requestGeneration)
                let startedAt = Date()
                let stats = Self.audioStats(samples: samples)
                DebugLog.shared.info("native ONNX audio samples loaded sampleRate=16000 samples=\(samples.count) rms=\(String(format: "%.5f", stats.rms)) peak=\(String(format: "%.5f", stats.peak))")
                let audioLoadedAt = Date()
                let text = try self.transcribeLoadedSamples(
                    samples,
                    vocabulary: vocabulary,
                    nativeVocabulary: nativeVocabulary,
                    preprocessor: preprocessor,
                    bridge: bridge,
                    priority: priority,
                    generation: requestGeneration,
                    startedAt: startedAt,
                    audioLoadedAt: audioLoadedAt
                )
                completion(.success(text))
            } catch {
                DebugLog.shared.error("native ONNX transcription failed: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private func transcribeLoadedSamples(
        _ samples: [Float],
        vocabulary: VocabularySettings,
        nativeVocabulary: NativeONNXVocabulary,
        preprocessor: NativeONNXPreprocessor,
        bridge: NativeONNXBridge,
        priority: TranscriptionPriority,
        generation: Int,
        startedAt: Date,
        audioLoadedAt: Date
    ) throws -> String {
        try checkCancellation(priority: priority, generation: generation)
        onProgress?("Preparing audio...")
        let features = preprocessor.features(samples: samples)
        DebugLog.shared.info("native ONNX features computed frames=\(features.length)")
        try checkCancellation(priority: priority, generation: generation)
        let featuresComputedAt = Date()
        onProgress?("Running encoder...")
        var encodedLength: Int64 = 0
        var outputShape: NSArray?
        let encoderOutput = try bridge.runEncoder(
            withFeatures: features.data,
            featureLength: Int64(features.length),
            encodedLength: &encodedLength,
            outputShape: &outputShape
        )
        DebugLog.shared.info("native ONNX encoder complete encodedLength=\(encodedLength) shape=\(outputShape ?? [])")
        try checkCancellation(priority: priority, generation: generation)
        let encoderCompletedAt = Date()
        onProgress?("Decoding...")
        let text = try NativeONNXDecoder.decode(
            encoderOutput: encoderOutput,
            outputShape: outputShape as? [NSNumber] ?? [],
            encodedLength: Int(encodedLength),
            bridge: bridge,
            vocabulary: nativeVocabulary
        )
        let decoderCompletedAt = Date()
        DebugLog.shared.info(
            "native ONNX timings audio=\(Self.formatDuration(audioLoadedAt.timeIntervalSince(startedAt))) features=\(Self.formatDuration(featuresComputedAt.timeIntervalSince(audioLoadedAt))) encoder=\(Self.formatDuration(encoderCompletedAt.timeIntervalSince(featuresComputedAt))) decoder=\(Self.formatDuration(decoderCompletedAt.timeIntervalSince(encoderCompletedAt))) total=\(Self.formatDuration(decoderCompletedAt.timeIntervalSince(startedAt)))"
        )
        return NativeONNXHotwords.apply(text: text, vocabulary: vocabulary)
    }

    private static func audioStats(samples: [Float]) -> (rms: Float, peak: Float) {
        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        return (samples.isEmpty ? 0 : sqrtf(sumSquares / Float(samples.count)), peak)
    }

    private func currentCancellationGeneration() -> Int {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationGeneration
    }

    private func checkCancellation(priority: TranscriptionPriority, generation: Int) throws {
        guard priority == .partialPreview else { return }
        if currentCancellationGeneration() != generation {
            throw NativeONNXRuntimeError.transcriptionCancelled
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.3fs", seconds)
    }

    private func preserveEmptyTranscriptAudio(_ audioURL: URL) {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(AppVariant.logDirectoryName, isDirectory: true)
        let destination = logs.appendingPathComponent("empty-transcript-\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try FileManager.default.copyItem(at: audioURL, to: destination)
            DebugLog.shared.info("preserved empty transcript audio: \(destination.path)")
        } catch {
            DebugLog.shared.warning("failed preserving empty transcript audio: \(error.localizedDescription)")
        }
    }
}

struct NativeONNXVocabulary {
    let tokens: [Int: String]
    let blankID: Int

    init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var tokens: [Int: String] = [:]
        var blankID: Int?

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let id = Int(parts[1]) else { continue }
            let token = String(parts[0]).replacingOccurrences(of: "\u{2581}", with: " ")
            tokens[id] = token
            if token == "<blk>" {
                blankID = id
            }
        }

        guard let blankID else {
            throw NativeONNXRuntimeError.invalidVocabulary(url.path)
        }
        self.tokens = tokens
        self.blankID = blankID
    }
}

final class NativeONNXPreprocessor {
    private let melFilterbanks: [Float]
    private let window: [Float]
    private let dftSetup: OpaquePointer

    private let nFFT = 512
    private let winLength = 400
    private let hopLength = 160
    private let featureCount = 128
    private let preemphasis: Float = 0.97
    private let logZeroGuard: Float = powf(2.0, -24.0)

    init(modelDirectory: URL) throws {
        let url = modelDirectory.appendingPathComponent("mel_fbanks_nemo128.bin")
        let data = try Data(contentsOf: url)
        let expectedCount = 257 * featureCount
        guard data.count == expectedCount * MemoryLayout<Float>.size else {
            throw NativeONNXRuntimeError.invalidMelFilterbank(url.path)
        }
        melFilterbanks = data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }

        let localNFFT = nFFT
        let localWinLength = winLength
        let sidePadding = (localNFFT - localWinLength) / 2
        let hann = (0..<localWinLength).map { index in
            Float(0.5 - 0.5 * cos((2.0 * Double.pi * Double(index)) / Double(localWinLength - 1)))
        }
        window = Array(repeating: 0, count: sidePadding) + hann + Array(repeating: 0, count: sidePadding)

        guard let dftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(localNFFT), .FORWARD) else {
            throw NativeONNXRuntimeError.invalidMelFilterbank(url.path)
        }
        self.dftSetup = dftSetup
    }

    deinit {
        vDSP_DFT_DestroySetup(dftSetup)
    }

    func features(samples: [Float]) -> (data: Data, length: Int) {
        let waveformLength = samples.count
        let featureLength = max(waveformLength / hopLength, 1)
        var waveform = Array(repeating: Float(0), count: waveformLength + nFFT)

        for index in 0..<waveformLength {
            let previous = index == 0 ? Float(0) : samples[index - 1]
            waveform[index + nFFT / 2] = samples[index] - preemphasis * previous
        }

        let frameCount = max((waveform.count - nFFT) / hopLength + 1, 1)
        var logMel = Array(repeating: Float(0), count: frameCount * featureCount)
        var powerSpectrum = Array(repeating: Float(0), count: 257)
        var melEnergies = Array(repeating: Float(0), count: featureCount)
        var realInput = Array(repeating: Float(0), count: nFFT)
        var imaginaryInput = Array(repeating: Float(0), count: nFFT)
        var realOutput = Array(repeating: Float(0), count: nFFT)
        var imaginaryOutput = Array(repeating: Float(0), count: nFFT)

        for frame in 0..<frameCount {
            let start = frame * hopLength
            for sampleIndex in 0..<nFFT {
                realInput[sampleIndex] = waveform[start + sampleIndex] * window[sampleIndex]
            }
            imaginaryInput.withUnsafeMutableBufferPointer { imaginaryInputBuffer in
                realInput.withUnsafeMutableBufferPointer { realInputBuffer in
                    realOutput.withUnsafeMutableBufferPointer { realOutputBuffer in
                        imaginaryOutput.withUnsafeMutableBufferPointer { imaginaryOutputBuffer in
                            vDSP_DFT_Execute(
                                dftSetup,
                                realInputBuffer.baseAddress!,
                                imaginaryInputBuffer.baseAddress!,
                                realOutputBuffer.baseAddress!,
                                imaginaryOutputBuffer.baseAddress!
                            )
                        }
                    }
                }
            }
            for bin in 0...nFFT / 2 {
                powerSpectrum[bin] = realOutput[bin] * realOutput[bin] + imaginaryOutput[bin] * imaginaryOutput[bin]
            }

            vDSP_mmul(
                powerSpectrum,
                1,
                melFilterbanks,
                1,
                &melEnergies,
                1,
                1,
                vDSP_Length(featureCount),
                257
            )
            for mel in 0..<featureCount {
                logMel[frame * featureCount + mel] = logf(melEnergies[mel] + logZeroGuard)
            }
        }

        let validFrames = min(featureLength, frameCount)
        var features = Array(repeating: Float(0), count: featureCount * frameCount)
        for mel in 0..<featureCount {
            var mean = Float(0)
            for frame in 0..<validFrames {
                mean += logMel[frame * featureCount + mel]
            }
            mean /= Float(validFrames)

            var variance = Float(0)
            for frame in 0..<validFrames {
                let centered = logMel[frame * featureCount + mel] - mean
                variance += centered * centered
            }
            variance /= Float(max(validFrames - 1, 1))
            let scale = sqrtf(variance) + 1e-5

            for frame in 0..<validFrames {
                features[mel * frameCount + frame] = (logMel[frame * featureCount + mel] - mean) / scale
            }
        }

        let data = features.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return (data, featureLength)
    }
}

enum NativeONNXDecoder {
    static func decode(encoderOutput: Data, outputShape: [NSNumber], encodedLength: Int, bridge: NativeONNXBridge, vocabulary: NativeONNXVocabulary) throws -> String {
        guard outputShape.count == 3 else {
            throw NativeONNXRuntimeError.invalidEncoderOutput
        }
        let firstDim = outputShape[0].intValue
        let middleDim = outputShape[1].intValue
        let lastDim = outputShape[2].intValue
        guard firstDim == 1, middleDim > 0, lastDim > 0 else {
            throw NativeONNXRuntimeError.invalidEncoderOutput
        }

        let encoderDim = middleDim
        let timeSteps = lastDim
        guard encoderOutput.count == encoderDim * timeSteps * MemoryLayout<Float>.size else {
            throw NativeONNXRuntimeError.invalidEncoderOutput
        }
        let encoderData = encoderOutput as NSData
        let encoderValues = encoderData.bytes.bindMemory(to: Float.self, capacity: encoderDim * timeSteps)

        var state1 = zeroState(shape: bridge.decoderState1Shape)
        var state2 = zeroState(shape: bridge.decoderState2Shape)
        let frameData = NSMutableData(length: encoderDim * MemoryLayout<Float>.size) ?? NSMutableData()
        let frameValues = frameData.mutableBytes.bindMemory(to: Float.self, capacity: encoderDim)
        var tokens: [Int] = []
        var emittedTokens = 0
        var time = 0
        let limit = min(encodedLength, timeSteps)

        while time < limit {
            for dim in 0..<encoderDim {
                frameValues[dim] = encoderValues[dim * timeSteps + time]
            }
            var nextState1: NSData?
            var nextState2: NSData?
            let target = Int64(tokens.last ?? vocabulary.blankID)
            let logitsData = try bridge.runDecoder(
                withEncoderFrame: frameData as Data,
                target: target,
                state1: state1 as Data,
                state2: state2 as Data,
                outputState1: &nextState1,
                outputState2: &nextState2
            )
            let tokenCount = vocabulary.tokens.count
            let logitCount = logitsData.count / MemoryLayout<Float>.size
            guard logitCount > tokenCount else {
                throw NativeONNXRuntimeError.invalidDecoderOutput
            }

            let (token, tokenScore, step, stepScore) = logitsData.withUnsafeBytes { buffer in
                let logits = buffer.bindMemory(to: Float.self)
                let tokenResult = argmax(logits, start: 0, count: tokenCount)
                let stepResult = argmax(logits, start: tokenCount, count: logitCount - tokenCount)
                return (tokenResult.index, tokenResult.value, stepResult.index, stepResult.value)
            }
            if time < 5 {
                DebugLog.shared.info("native ONNX decode step time=\(time) token=\(token) blank=\(vocabulary.blankID) tokenScore=\(String(format: "%.3f", tokenScore)) step=\(step) stepScore=\(String(format: "%.3f", stepScore))")
            }
            if token != vocabulary.blankID {
                tokens.append(token)
                emittedTokens += 1
                if let nextState1, let nextState2 {
                    state1 = nextState1
                    state2 = nextState2
                }
            }

            if step > 0 {
                time += step
                emittedTokens = 0
            } else if token == vocabulary.blankID || emittedTokens == 10 {
                time += 1
                emittedTokens = 0
            }
        }

        DebugLog.shared.info("native ONNX decoder complete tokens=\(tokens.count) frames=\(limit)")
        return decodeTokens(tokens, vocabulary: vocabulary)
    }

    private static func zeroState(shape: [NSNumber]) -> NSData {
        let count = shape.reduce(1) { $0 * $1.intValue }
        return NSMutableData(length: count * MemoryLayout<Float>.size) ?? NSData()
    }

    private static func argmax(_ values: UnsafeBufferPointer<Float>, start: Int, count: Int) -> (index: Int, value: Float) {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for offset in 0..<count {
            let value = values[start + offset]
            guard value > bestValue else { continue }
            bestIndex = offset
            bestValue = value
        }
        return (bestIndex, bestValue)
    }

    private static func decodeTokens(_ tokenIDs: [Int], vocabulary: NativeONNXVocabulary) -> String {
        let raw = tokenIDs.compactMap { vocabulary.tokens[$0] }.joined()
        return raw.replacingOccurrences(of: #"\A\s|\s\B|(\s)\b"#, with: "$1", options: .regularExpression)
    }
}

enum NativeONNXHotwords {
    static func apply(text: String, vocabulary: VocabularySettings) -> String {
        var result = text
        for entry in vocabulary.words {
            let parts = entry.contains("=>") ? entry.components(separatedBy: "=>") : entry.components(separatedBy: "->")
            let spoken = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : spoken
            guard !spoken.isEmpty, !replacement.isEmpty else { continue }
            result = result.replacingOccurrences(of: spoken, with: replacement, options: [.caseInsensitive, .diacriticInsensitive])
        }
        return result
    }
}

struct NativeONNXWAVAudio {
    let sampleRate: Int
    let samples: [Float]
    let rms: Float
    let peak: Float

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              data.asciiString(in: 0..<4) == "RIFF",
              data.asciiString(in: 8..<12) == "WAVE" else {
            throw NativeONNXRuntimeError.invalidWAV(url.path)
        }

        var offset = 12
        var audioFormat: UInt16?
        var channelCount: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var payloadRange: Range<Int>?

        while offset + 8 <= data.count {
            let chunkID = data.asciiString(in: offset..<(offset + 4))
            let chunkSize = Int(data.uint32LE(at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else {
                throw NativeONNXRuntimeError.invalidWAV(url.path)
            }

            switch chunkID {
            case "fmt ":
                guard chunkSize >= 16 else { throw NativeONNXRuntimeError.invalidWAV(url.path) }
                audioFormat = data.uint16LE(at: payloadStart)
                channelCount = data.uint16LE(at: payloadStart + 2)
                sampleRate = data.uint32LE(at: payloadStart + 4)
                bitsPerSample = data.uint16LE(at: payloadStart + 14)
            case "data":
                payloadRange = payloadStart..<payloadEnd
            default:
                break
            }

            offset = payloadEnd + (chunkSize % 2)
        }

        guard audioFormat == 1, channelCount == 1, bitsPerSample == 16, let sampleRate, let payloadRange else {
            throw NativeONNXRuntimeError.unsupportedWAV(url.path)
        }
        guard sampleRate == 16_000 else {
            throw NativeONNXRuntimeError.unsupportedWAV(url.path)
        }

        self.sampleRate = Int(sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(payloadRange.count / 2)
        var sampleOffset = payloadRange.lowerBound
        while sampleOffset + 2 <= payloadRange.upperBound {
            samples.append(Float(data.int16LE(at: sampleOffset)) / 32768.0)
            sampleOffset += 2
        }
        self.samples = samples
        var sumSquares = Float(0)
        var peak = Float(0)
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        self.rms = samples.isEmpty ? 0 : sqrtf(sumSquares / Float(samples.count))
        self.peak = peak
    }
}

enum NativeONNXRuntimeError: LocalizedError {
    case missingModelFiles(String, [String])
    case invalidVocabulary(String)
    case invalidMelFilterbank(String)
    case invalidWAV(String)
    case unsupportedWAV(String)
    case invalidEncoderOutput
    case invalidDecoderOutput
    case notReady
    case notImplemented
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .missingModelFiles(let directory, let files):
            return "ONNX model package at \(directory) is missing: \(files.joined(separator: ", "))"
        case .invalidVocabulary(let path):
            return "Invalid ONNX vocabulary at \(path)"
        case .invalidMelFilterbank(let path):
            return "Invalid ONNX mel filterbank at \(path)"
        case .invalidWAV(let path):
            return "Invalid WAV file at \(path)"
        case .unsupportedWAV(let path):
            return "Unsupported WAV format at \(path); expected 16 kHz mono PCM16"
        case .invalidEncoderOutput:
            return "Invalid ONNX encoder output"
        case .invalidDecoderOutput:
            return "Invalid ONNX decoder output"
        case .notReady:
            return "Native ONNX runtime is not ready"
        case .notImplemented:
            return "Native ONNX runtime is not implemented yet"
        case .transcriptionCancelled:
            return "Transcription request was cancelled"
        }
    }
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return String(data: self.subdata(in: range), encoding: .ascii)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
