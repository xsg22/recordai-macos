import AVFoundation
import Foundation

/// 完全使用合成音频，不请求权限、不访问麦克风或系统音频。
@main
struct RecorderSmoke {
    @MainActor static func main() async throws {
        // 时间对齐使用音频时间戳，即便回调延迟抵达也不能改变 offset。
        var timeline = MeetingCaptureTimeline(started: 100)
        timeline.setPaused(true, at: 101)
        timeline.setPaused(false, at: 103)
        let spanning = timeline.slices(at: 100.5, frames: 144_000, sampleRate: 48_000)
        precondition(spanning.count == 2)
        precondition(spanning[0].frames == 0..<24_000 && spanning[0].offset == 0.5)
        precondition(spanning[1].frames == 120_000..<144_000 && spanning[1].offset == 1)
        precondition(timeline.slices(at: 102, frames: 4800, sampleRate: 48_000).isEmpty)
        let afterPause = timeline.slices(at: 103.5, frames: 4800, sampleRate: 48_000)
        precondition(afterPause[0].offset == 1.5)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 在没有默认输入设备的机器上验证真实启动与重试均安全失败。
        if (try? MeetingRecorder.requireMicrophone()) == nil {
            let recorder = MeetingRecorder()
            do {
                try await recorder.start(mode: .microphone, directory: root)
                preconditionFailure("没有输入设备时不能开始录音")
            } catch {
                precondition(error.localizedDescription.contains("输入设备"))
                precondition(recorder.state == .idle && !recorder.resume())
            }
        }
        let microphone = root.appendingPathComponent("microphone.caf")
        let system = root.appendingPathComponent("system.caf")
        try tone(url: microphone, frequency: 440)
        try tone(url: system, frequency: 880)
        // 真实 writer 的样本时间戳间隔产生静音，而不是拼接缩短时间。
        let rawDirectory = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let sink = MeetingAudioSink(directory: rawDirectory, started: 100) { error in
            fatalError("writer unexpected error: \(error)")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        sourceBuffer.frameLength = 48_000
        for frame in 0..<48_000 { sourceBuffer.floatChannelData![0][frame] = 0.2 }
        sink.appendMicrophone(sourceBuffer, at: 100.2)
        sink.appendMicrophone(sourceBuffer, at: 101.7)
        let rawTracks = sink.finish()
        precondition(abs(rawTracks[0].offset - 0.2) < 0.0001)
        let persisted = try JSONDecoder().decode([MeetingAudioTrack].self, from: Data(contentsOf: rawDirectory.appendingPathComponent("recording.json")))
        precondition(persisted.count == 1 && persisted[0].url == rawTracks[0].url)
        let rawFile = try AVAudioFile(forReading: rawTracks[0].url)
        precondition(rawFile.length == 120_000, "两段 1s 录音之间应保留 0.5s 静音")
        let rawBuffer = AVAudioPCMBuffer(pcmFormat: rawFile.processingFormat, frameCapacity: 120_000)!
        try rawFile.read(into: rawBuffer)
        precondition(abs(rawBuffer.floatChannelData![0][60_000]) < 0.0001)
        // 无权限/目录不可写等存储失败只能回调一次，stop 仍能同步读到错误。
        let badDirectory = root.appendingPathComponent("missing/subdirectory")
        var writeFailures = 0
        let brokenSink = MeetingAudioSink(directory: badDirectory, started: 100) { _ in writeFailures += 1 }
        brokenSink.appendMicrophone(sourceBuffer, at: 100)
        brokenSink.appendMicrophone(sourceBuffer, at: 101)
        _ = brokenSink.finish()
        precondition(brokenSink.recordingError != nil && writeFailures == 1)
        let output = root.appendingPathComponent("meeting.m4a")
        try await MeetingAudioMixer.mix(tracks: [
            MeetingAudioTrack(kind: .microphone, url: microphone, offset: 0),
            MeetingAudioTrack(kind: .system, url: system, offset: 0.25)
        ], destination: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        precondition(abs(duration - 1.25) < 0.08, "合成必须保留两轨时间偏移")
        let file = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let sampleRate = buffer.format.sampleRate
        // 在重叠区检测两种频率，防止合成时只留下系统声音或只留下麦克风。
        let start = Int(sampleRate * 0.4)
        let count = Int(sampleRate * 0.4)
        for frequency in [440.0, 880.0] {
            var real = 0.0
            var imaginary = 0.0
            for frame in start..<(start + count) {
                let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
                real += Double(samples[frame]) * cos(phase)
                imaginary += Double(samples[frame]) * sin(phase)
            }
            let amplitude = 2 * hypot(real, imaginary) / Double(count)
            precondition(amplitude > 0.07, "混音丢失 \(frequency) Hz 音轨")
        }
        precondition(FileManager.default.fileExists(atPath: microphone.path))
        precondition(FileManager.default.fileExists(atPath: system.path))
        precondition(MeetingRecordingMode.meeting.needsMicrophone && MeetingRecordingMode.meeting.needsSystemAudio)
        precondition(!MeetingRecordingMode.systemAudio.needsMicrophone)
        // 同相满幅双轨比普通双音调更容易削波，验证混音增益保留编码余量。
        let loud = root.appendingPathComponent("loud.caf")
        try tone(url: loud, frequency: 440, amplitude: 0.99)
        let loudMix = root.appendingPathComponent("loud.m4a")
        try await MeetingAudioMixer.mix(tracks: [
            MeetingAudioTrack(kind: .microphone, url: loud, offset: 0),
            MeetingAudioTrack(kind: .system, url: loud, offset: 0)
        ], destination: loudMix)
        let loudFile = try AVAudioFile(forReading: loudMix)
        let loudBuffer = AVAudioPCMBuffer(pcmFormat: loudFile.processingFormat, frameCapacity: AVAudioFrameCount(loudFile.length))!
        try loudFile.read(into: loudBuffer)
        var peak: Float = 0
        for frame in 0..<Int(loudBuffer.frameLength) { peak = max(peak, abs(loudBuffer.floatChannelData![0][frame])) }
        precondition(peak > 0.8 && peak < 0.98, "双轨满幅混音应保留余量而不是削波")
        let padded = root.appendingPathComponent("padded.m4a")
        try await MeetingAudioMixer.mix(tracks: rawTracks, destination: padded, duration: 3)
        let paddedDuration = try await AVURLAsset(url: padded).load(.duration).seconds
        precondition(abs(paddedDuration - 3) < 0.03, "停止后混音必须保留首包延迟和尾部静音，时长应与录音一致")
        // 无效任务必须失败，不能覆盖已有合成结果。
        do {
            try await MeetingAudioMixer.mix(tracks: [], destination: output)
            preconditionFailure("空音轨应拒绝")
        } catch {}
        do {
            try await MeetingAudioMixer.mix(tracks: rawTracks, destination: output)
            preconditionFailure("已有文件应拒绝覆盖")
        } catch {}
        print("PASS: 暂停边界裁剪、host 时间戳对齐、缺帧补静音、恢复清单、写盘错误、满幅混音防削波、准确停止时长、两轨混音与起始偏移、原轨保留、拒绝覆盖。没有采集真实音频。")
    }

    static func tone(url: URL, frequency: Double, amplitude: Double = 0.3) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for frame in 0..<48_000 {
            buffer.floatChannelData![0][frame] = Float(amplitude * sin(2 * Double.pi * frequency * Double(frame) / 48_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
