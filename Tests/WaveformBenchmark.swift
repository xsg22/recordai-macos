import AVFoundation
import Darwin
import Foundation

/// 可重复的声波计算探针，仅合成文件，无录音/扬声器；不用于竞品ASR排名。
@main struct WaveformBenchmark {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cohear-wave-bench-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("ten-minutes.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for frame in 0..<16_000 {
            buffer.floatChannelData![0][frame] = 0.3 * sin(2 * .pi * Float(frame) * 440 / 16_000)
            buffer.floatChannelData![1][frame] = 0.4 * sin(2 * .pi * Float(frame) * 660 / 16_000)
        }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            for _ in 0..<600 { try file.write(from: buffer) }
        }
        let cache = root.appendingPathComponent("cache")
        let store = AudioWaveformStore(directory: cache)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await store.load(audio)
        let cold = ProcessInfo.processInfo.systemUptime - start
        let diskStart = ProcessInfo.processInfo.systemUptime
        _ = try await AudioWaveformStore(directory: cache).load(audio)
        let disk = ProcessInfo.processInfo.systemUptime - diskStart
        let memoryStart = ProcessInfo.processInfo.systemUptime
        _ = try await store.load(audio)
        let memory = ProcessInfo.processInfo.systemUptime - memoryStart
        precondition(abs(result.duration - 600) < 0.001 && result.peaks.count == 2048)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["sample": "10-minute synthetic stereo CAF, 16kHz Float32", "durationSeconds": result.duration,
            "fileBytes": (try fm.attributesOfItem(atPath: audio.path)[.size] as? NSNumber) ?? 0, "peakCount": result.peaks.count,
            "coldSeconds": cold, "diskCacheSeconds": disk, "memoryCacheSeconds": memory, "processPeakRSSBytes": usage.ru_maxrss,
            "conditions": "local developer Mac; package build may run concurrently; no microphone or sound playback; not a cross-device benchmark"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
    }
}
