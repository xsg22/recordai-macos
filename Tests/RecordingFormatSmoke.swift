import Foundation
import AVFoundation

/// 经过真实录音混音器生成M4A，再走与停止录音相同的定稿链路；不请求麦克风权限。
@main struct RecordingFormatSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        let worker = URL(fileURLWithPath: args[1]), model = URL(fileURLWithPath: args[2])
        let source = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func convert(_ source: URL, _ destination: URL, _ options: [String]) throws {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            child.arguments = options + [source.path, destination.path]
            try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
        }
        let microphone = output.appendingPathComponent("microphone.caf")
        let system = output.appendingPathComponent("system.caf")
        try convert(source, microphone, ["-f", "caff", "-d", "LEF32@48000", "-c", "1"])
        try convert(source, system, ["-f", "caff", "-d", "LEF32@48000", "-c", "2"])
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        for dual in [false, true] {
            var tracks = [MeetingAudioTrack(kind: .microphone, url: microphone, offset: 0)]
            if dual { tracks.append(.init(kind: .system, url: system, offset: 0)) }
            let m4a = output.appendingPathComponent(dual ? "dual-recording.m4a" : "microphone-recording.m4a")
            try await MeetingAudioMixer.mix(tracks: tracks, destination: m4a, duration: duration)
            let wav = m4a.deletingPathExtension().appendingPathExtension("wav")
            try convert(m4a, wav, ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])
            let bytes = [UInt8](try Data(contentsOf: wav))
            var cursor = 12, formatSize: UInt32 = 0
            while cursor + 8 <= bytes.count {
                let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[cursor + 4 + $1]) << ($1 * 8) }
                if Array(bytes[cursor..<cursor+4]) == Array("fmt ".utf8) { formatSize = size; break }
                cursor += 8 + Int(size) + Int(size % 2)
            }
            if !dual { precondition(formatSize == 40, "单麦克风录音必须覆盖此前失败的WAVE扩展格式头") }
            else { precondition([UInt32(16), 40].contains(formatSize)) }
            let result = try TranscriptionEngine().transcribe(audio: m4a, model: model, executable: worker, language: "zh")
            precondition(result.text.contains("会议") && result.text.contains("本地") && result.subtitles.contains("-->"))
            print("PASS: \(dual ? "双轨立体声" : "单麦克风") CAF → 系统混音M4A → fmt\(formatSize) WAV → Silero → 真实Qwen正文/SRT")
            fflush(stdout)
        }
        let baseline = try TranscriptionEngine().transcribe(audio: source, model: model, executable: worker, language: "zh")
        precondition(baseline.text.contains("会议"))
        print("PASS: 原有AIFF/fmt16路径仍正常；仅合成音频，无麦克风或私人会议。")
    }
}
