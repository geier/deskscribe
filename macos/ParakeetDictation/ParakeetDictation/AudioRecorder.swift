import AVFoundation
import Foundation

final class AudioRecorder {
    private let sampleRate = 16_000.0
    private let queue = DispatchQueue(label: "ParakeetDictation.AudioRecorder")
    private var engine: AVAudioEngine?
    private var inputSampleRate = 44_100.0
    private var samples: [Float] = []

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputSampleRate = format.sampleRate

        queue.sync {
            samples.removeAll(keepingCapacity: true)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func snapshot() -> URL? {
        let state = queue.sync { (samples, inputSampleRate) }
        guard state.0.count > 0 else { return nil }
        return writeWav(samples: state.0, sourceSampleRate: state.1)
    }

    func stop() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        let state = queue.sync { () -> ([Float], Double) in
            defer { samples.removeAll(keepingCapacity: false) }
            return (samples, inputSampleRate)
        }

        guard state.0.count > 0 else { return nil }
        return writeWav(samples: state.0, sourceSampleRate: state.1)
    }

    func cancel() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        queue.sync {
            samples.removeAll(keepingCapacity: false)
        }
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        var mono = [Float](repeating: 0, count: frameCount)

        for channel in 0..<channelCount {
            let data = channelData[channel]
            for frame in 0..<frameCount {
                mono[frame] += data[frame] / Float(channelCount)
            }
        }

        queue.async { [mono] in
            self.samples.append(contentsOf: mono)
        }
    }

    private func writeWav(samples: [Float], sourceSampleRate: Double) -> URL? {
        let resampled = resample(samples: samples, sourceSampleRate: sourceSampleRate)
        guard !resampled.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetDictation-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        var data = Data()
        let bytesPerSample = 2
        let channelCount = 1
        let byteRate = Int(sampleRate) * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample
        let payloadSize = resampled.count * bytesPerSample

        data.appendString("RIFF")
        data.appendUInt32LE(UInt32(36 + payloadSize))
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(UInt16(channelCount))
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(UInt16(blockAlign))
        data.appendUInt16LE(UInt16(bytesPerSample * 8))
        data.appendString("data")
        data.appendUInt32LE(UInt32(payloadSize))

        for sample in resampled {
            let clamped = max(-1.0, min(1.0, sample))
            data.appendInt16LE(Int16(clamped * Float(Int16.max)))
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            DebugLog.shared.error("failed writing WAV snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    private func resample(samples: [Float], sourceSampleRate: Double) -> [Float] {
        guard sourceSampleRate > 0, sourceSampleRate != sampleRate else { return samples }

        let duration = Double(samples.count) / sourceSampleRate
        let outputCount = Int(duration * sampleRate)
        guard outputCount > 0 else { return [] }

        let ratio = sourceSampleRate / sampleRate
        return (0..<outputCount).map { index in
            let sourcePosition = Double(index) * ratio
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendInt16LE(_ value: Int16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
    }
}
