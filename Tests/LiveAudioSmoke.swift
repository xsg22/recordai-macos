import AVFoundation
import Foundation

/// 纯合成样本验证，不请求录音权限、不读取未关闭录音文件。
@main
struct LiveAudioSmoke {
    static func main() throws {
        var output: [Float] = []
        var largest = 0
        let mixer = MeetingLiveAudioMixer(trackCount: 2) { samples, _ in
            largest = max(largest, samples.count)
            output += samples
        }
        // 以20ms包模拟两轨交错抵达；系统轨延后60ms起声且回调顺序不断变化。
        for packet in 0..<50 {
            let offset = Double(packet) * 0.02
            let mic = tone(frequency: 440, start: packet * 320, count: 320)
            let system = tone(frequency: 880, start: packet * 320, count: 320)
            if packet % 2 == 0 {
                mixer.append(system, kind: .system, offset: offset + 0.06)
                mixer.append(mic, kind: .microphone, offset: offset)
            } else {
                mixer.append(mic, kind: .microphone, offset: offset)
                mixer.append(system, kind: .system, offset: offset + 0.06)
            }
            precondition(mixer.bufferedFrames <= 8000)
        }
        mixer.flush()
        precondition(output.count == 16_960 && largest <= 1600)
        for frequency in [440.0, 880.0] {
            precondition(amplitude(output, frequency: frequency, range: 6400..<12800) > 0.1, "两轨声音必须同时保留")
        }
        precondition(amplitude(output, frequency: 880, range: 0..<800) < 0.01, "系统轨起点不能提前")
        let total = output.count
        mixer.append([Float](repeating: 1, count: 320), kind: .microphone, offset: 0)
        mixer.flush()
        precondition(output.count == total, "迟到旧包不能重复发送")

        // 暂停10秒不进入样本时间轴；恢复后的实时音频紧接上一段。
        var timeline = MeetingCaptureTimeline(started: 100)
        timeline.setPaused(true, at: 101)
        timeline.setPaused(false, at: 111)
        precondition(timeline.slices(at: 105, frames: 480, sampleRate: 48_000).isEmpty)
        let resumed = timeline.slices(at: 111, frames: 960, sampleRate: 48_000)
        precondition(resumed.count == 1 && abs(resumed[0].offset - 1) < 0.0001)

        // 连续48k stereo输入转16k mono，验证重采样状态和尾部flush。
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let resampler = try MeetingLiveResampler(format: format)
        var converted: [Float] = []
        for packet in 0..<50 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for frame in 0..<960 {
                let value = Float(0.3 * sin(2 * Double.pi * 440 * Double(packet * 960 + frame) / 48_000))
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            let result = try resampler.convert(buffer, offset: Double(packet) * 0.02)
            precondition(abs(result.offset - Double(converted.count) / 16_000) < 0.0001)
            converted += result.samples
        }
        converted += try resampler.finish().samples
        precondition(abs(converted.count - 16_000) < 32, "重采样不能持续丢帧或增长")
        precondition(amplitude(converted, frequency: 440, range: 3200..<12800) > 0.25)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-audio-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var delivered = 0
        let sink = MeetingAudioSink(directory: directory, started: 100, onAudio: { delivered += $0.count }) { error in
            fatalError("Unexpected writer error: \(error)")
        }
        for packet in 0..<20 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for channel in 0..<2 {
                for frame in 0..<960 { buffer.floatChannelData![channel][frame] = 0.1 }
            }
            sink.appendMicrophone(buffer, at: 100 + Double(packet) * 0.02)
        }
        let tracks = sink.finish()
        precondition(tracks.count == 1 && abs(delivered - 6400) < 32, "finish必须交付尾部实时样本")
        print("PASS: 16k mono双轨混音、200ms乱序缓冲、真实起点、暂停时间压缩、48k stereo重采样、尾部flush、有界缓存和回调批量。未录制真实音频。")
    }

    static func tone(frequency: Double, start: Int, count: Int) -> [Float] {
        (start..<(start + count)).map { Float(0.3 * sin(2 * Double.pi * frequency * Double($0) / 16_000)) }
    }

    static func amplitude(_ samples: [Float], frequency: Double, range: Range<Int>) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for index in range {
            let phase = 2 * Double.pi * frequency * Double(index) / 16_000
            real += Double(samples[index]) * cos(phase)
            imaginary += Double(samples[index]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(range.count)
    }
}
