import Foundation

@main
struct EngineSmoke {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("usage: smoke engine model audio outputDirectory") }
        let engine = TranscriptionEngine()
        let result = try engine.transcribe(audio: URL(fileURLWithPath: args[3]), model: URL(fileURLWithPath: args[2]),
                                           executable: URL(fileURLWithPath: args[1]), language: "zh")
        guard !result.text.isEmpty, result.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              result.subtitles.contains("-->") else { throw TranscriptionError.message("未生成中文转录和字幕") }
        let out = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try result.text.write(to: out.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try result.subtitles.write(to: out.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
        let cancelled = TranscriptionEngine()
        cancelled.cancel()
        do {
            _ = try cancelled.transcribe(audio: URL(fileURLWithPath: args[3]), model: URL(fileURLWithPath: args[2]),
                                          executable: URL(fileURLWithPath: args[1]), language: "zh")
            throw TranscriptionError.message("取消任务未生效")
        } catch is CancellationError { }
        print("中文转录、SRT 字幕、预取消验证通过：\n\(result.text)")
    }
}
