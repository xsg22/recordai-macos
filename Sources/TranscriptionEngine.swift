import Foundation

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

struct TranscriptionOutput: Sendable {
    let text: String
    let subtitles: String
    var paragraphs: [TranscriptParagraph] = []
}

/// 每次任务拥有独立进程和临时目录；取消不会影响其他任务或留下半成品。
final class TranscriptionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    private func run(_ executable: URL, _ arguments: [String], directory: URL, stage: String) throws {
        let logURL = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = log
        child.standardError = log
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        child.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw TranscriptionError.message("\(stage)失败（代码 \(child.terminationStatus)）。原始录音和已有文字已保留，可以重试。\n\n" + String(details.suffix(1800)))
        }
    }

    func transcribe(audio: URL, model: URL, executable: URL, language: String) throws -> TranscriptionOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoHear-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("audio.wav")
        try run(URL(fileURLWithPath: "/usr/bin/afconvert"),
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path], directory: directory, stage: "音频格式转换")
        let segmenter = executable.deletingLastPathComponent().appendingPathComponent("paraformer-live")
        let paraformer = model.deletingLastPathComponent().appendingPathComponent("Paraformer")
        let segments = directory.appendingPathComponent("segments", isDirectory: true)
        try run(segmenter, ["segment", paraformer.path, wav.path, segments.path], directory: directory, stage: "语音片段检测")
        let manifest = segments.appendingPathComponent("segments.json")
        guard let detected = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]] else {
            throw TranscriptionError.message("语音检测结果无效，原录音已保留。")
        }
        if detected.isEmpty { return TranscriptionOutput(text: "", subtitles: "") }
        let output = directory.appendingPathComponent("transcript.json")
        try run(executable, [model.path, manifest.path, language, output.path], directory: directory, stage: "Qwen语音定稿")
        let response = try JSONDecoder().decode(QwenOutput.self, from: Data(contentsOf: output))
        guard response.segments.count == detected.count else {
            throw TranscriptionError.message("定稿未覆盖全部语音片段，未保存部分结果。")
        }
        var subtitles: [String] = []
        for (index, segment) in response.segments.enumerated() {
            guard let start = detected[index]["start"] as? Double, let end = detected[index]["end"] as? Double,
                  abs(segment.start - start) < 0.001, abs(segment.end - end) < 0.001 else {
                throw TranscriptionError.message("定稿片段与语音时间不一致，未保存部分结果。")
            }
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else {
                throw TranscriptionError.message("语音片段时间无效。")
            }
            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subtitles.append("\(subtitles.count + 1)\n\(Self.timestamp(segment.start)) --> \(Self.timestamp(segment.end))\n\(segment.text)")
            }
        }
        let nonempty = response.segments.filter { !$0.text.isEmpty }
        let paragraphs = nonempty.enumerated().map { index, segment in
            TranscriptParagraph(text: segment.text, separator: index == 0 ? "" : "\n", start: segment.start, end: segment.end)
        }
        return TranscriptionOutput(text: nonempty.map(\.text).joined(separator: "\n"),
                                   subtitles: subtitles.isEmpty ? "" : subtitles.joined(separator: "\n\n") + "\n\n", paragraphs: paragraphs)
    }

    /// 正文已经提交后再调用；分析失败由调用方保留正式转录，不回滚为转录失败。
    func analyzeSpeakers(audio: URL, model: URL, executable: URL, transcript: TranscriptionOutput, language: String = "zh",
                         onPhase: @escaping @Sendable (TranscriptPhase) -> Void = { _ in }) throws -> [TranscriptParagraph] {
        if transcript.paragraphs.isEmpty { return [] }
        let root = model.deletingLastPathComponent()
        let sortformer = root.appendingPathComponent("Sortformer"), aligner = root.appendingPathComponent("QwenAligner")
        guard [sortformer, aligner].allSatisfy({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.safetensors").path) }) else {
            throw TranscriptionError.message("发言人模型缺失，请在设置中重新下载。正文已保存。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoHear-speakers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("audio.wav")
        try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path], directory: directory, stage: "录音读取")
        let segments = directory.appendingPathComponent("segments")
        try run(executable.deletingLastPathComponent().appendingPathComponent("paraformer-live"),
                ["segment", root.appendingPathComponent("Paraformer").path, wav.path, segments.path], directory: directory, stage: "语音片段检测")
        let manifest = segments.appendingPathComponent("segments.json")
        guard let detected = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]] else {
            throw TranscriptionError.message("语音片段数据无效。")
        }
        var clips: [[String: Any]] = []
        for paragraph in transcript.paragraphs {
            guard let start = paragraph.start, let end = paragraph.end,
                  var clip = detected.first(where: { item in
                      guard let s = item["start"] as? Double, let e = item["end"] as? Double else { return false }
                      return abs(s - start) < 0.001 && abs(e - end) < 0.001
                  }) else { throw TranscriptionError.message("文字与录音片段不一致，未强行添加发言人。") }
            clip["text"] = paragraph.text; clip["language"] = language
            clips.append(clip)
        }
        try JSONSerialization.data(withJSONObject: clips).write(to: manifest, options: .atomic)
        let turns = directory.appendingPathComponent("turns.json"), aligned = directory.appendingPathComponent("aligned.json")
        onPhase(.diarizing)
        try run(executable, ["--diarize", sortformer.path, wav.path, turns.path], directory: directory, stage: "发言人区分")
        onPhase(.aligning)
        try run(executable, ["--align-speakers", aligner.path, manifest.path, turns.path, aligned.path], directory: directory, stage: "发言人与文字对齐")
        struct Response: Decodable {
            struct Row: Decodable { let text: String; let separator: String; let start: Double; let end: Double; let speakerIDs: [String] }
            let paragraphs: [Row]
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(contentsOf: aligned))
        guard response.paragraphs.map({ $0.separator + $0.text }).joined() == transcript.text else {
            throw TranscriptionError.message("发言人分段与正文不一致，已保留正文。")
        }
        return try response.paragraphs.map { row in
            guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end >= row.start,
                  row.speakerIDs.count <= 4, row.speakerIDs.allSatisfy({ ["0", "1", "2", "3"].contains($0) }) else {
                throw TranscriptionError.message("发言人时间或编号无效。")
            }
            return TranscriptParagraph(text: row.text, separator: row.separator, start: row.start, end: row.end, speakerIDs: row.speakerIDs)
        }
    }

    private struct QwenOutput: Decodable {
        struct Segment: Decodable { let text: String; let start: Double; let end: Double }
        let segments: [Segment]
    }
    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
