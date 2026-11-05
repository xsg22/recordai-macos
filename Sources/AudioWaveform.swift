import AVFoundation
import CryptoKit
import Foundation

struct AudioWaveform: Codable, Sendable {
    let identity: String
    let duration: Double
    let peaks: [Float]
}

/// 串行后台actor，分块解码并限制峰值数量；不等待此任务即可开始播放。
actor AudioWaveformStore {
    static let shared = AudioWaveformStore()
    private let directory: URL
    private var memory: [String: AudioWaveform] = [:]
    private var recent: [String] = []
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoHearTranscribe/Waveforms-v1")
    }
    private func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
            throw MeetingRecorderError.message("无法读取音频文件信息。")
        }
        let source = "v1|\(url.resolvingSymlinksInPath().path)|\(bytes)|\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load(_ url: URL) throws -> AudioWaveform {
        try Task.checkCancellation()
        let key = try identity(url)
        if let cached = memory[key] { remember(cached); return cached }
        let cache = directory.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode(AudioWaveform.self, from: data),
           cached.identity == key, cached.duration.isFinite, cached.duration > 0, cached.peaks.count <= 2048,
           !cached.peaks.isEmpty, cached.peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
            remember(cached); return cached
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MeetingRecorderError.message("音频为空或无法生成声波。")
        }
        let frames = file.length, duration = Double(frames) / format.sampleRate
        guard duration.isFinite, duration > 0 else { throw MeetingRecorderError.message("音频时长无效。") }
        let bins = max(1, Int(min(2048, min(Double(frames), ceil(duration * 40)))))
        var peaks = [Float](repeating: 0, count: bins)
        var offset: AVAudioFramePosition = 0
        while offset < frames {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, frames - offset)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw MeetingRecorderError.message("音频读取提前结束，声波未完成。")
            }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(bins - 1, Int(Double(offset + Int64(frame)) / Double(frames) * Double(bins)))
                for channel in 0..<Int(format.channelCount) {
                    let value = abs(channels[channel][frame])
                    if value.isFinite { peaks[bin] = max(peaks[bin], min(1, value)) }
                }
            }
            offset += Int64(buffer.frameLength)
        }
        try Task.checkCancellation()
        guard try identity(url) == key else { throw MeetingRecorderError.message("音频已变化，请重新加载声波。") }
        let result = AudioWaveform(identity: key, duration: duration, peaks: peaks)
        remember(result)
        // 缓存故障不影响音频、回放和本次计算结果。
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: cache, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" }
            if files.count > 64 {
                let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for old in ordered.prefix(files.count - 64) where old != cache { try? FileManager.default.removeItem(at: old) }
            }
        } catch { }
        return result
    }
    private func remember(_ waveform: AudioWaveform) {
        memory[waveform.identity] = waveform
        recent.removeAll { $0 == waveform.identity }; recent.append(waveform.identity)
        while recent.count > 8 { memory.removeValue(forKey: recent.removeFirst()) }
    }
}

/// 帧到达与声音大小是两件事：真正的静音也有音频帧，不因此误报设备断开。
enum CaptureHealth {
    static func microphoneStalled(started: TimeInterval, lastFrame: TimeInterval?, now: TimeInterval) -> Bool {
        now - started >= 8 && now - (lastFrame ?? started) >= 5
    }
}
