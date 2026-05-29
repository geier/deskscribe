import AVFoundation
import Foundation

final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetDictation-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw NSError(domain: "ParakeetDictation.AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAudioRecorder failed to start"
            ])
        }

        self.recorder = recorder
        currentURL = url
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        defer { currentURL = nil }
        return currentURL
    }
}
