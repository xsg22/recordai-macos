import Foundation
import AVFoundation
import Darwin

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

private struct HotwordHints: Encodable { let words: [String]; let context: String }

struct TranscriptionOutput: Sendable {
    let text: String
    let subtitles: String
    var paragraphs: [TranscriptParagraph] = []
}

/// 每次任务拥有独立进程和临时目录；取消不会影响其他任务或留下半成品。
final class TranscriptionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let temporaryRoot: URL
    private var process: Process?
    private var cancelled = false

    init(temporaryRoot: URL? = nil) {
        let configured = ProcessInfo.processInfo.environment["RECORD_AI_TRANSCRIPTION_TMP_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.temporaryRoot = temporaryRoot ?? configured ?? FileManager.default.temporaryDirectory
    }
    private func temporaryDirectory(prefix: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard temporaryRoot.isFileURL, FileManager.default.fileExists(atPath: temporaryRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TranscriptionError.message("转录临时目录不可用，请检查存储设备。")
        }
        let directory = temporaryRoot.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

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

    /// Feed bounded PCM into a single child process. A socket with
    /// SO_NOSIGPIPE turns a prematurely exited worker into a recoverable error
    /// rather than terminating the app while it is writing audio.
    private func runStreaming(_ executable: URL, _ arguments: [String], directory: URL, stage: String,
                              feed: (FileHandle) throws -> Void) throws {
        let logURL = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw TranscriptionError.message("无法建立音频流。") }
        let output = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        let input = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        defer { try? output.close(); try? input.close() }
        guard fcntl(sockets[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(sockets[1], F_SETFD, FD_CLOEXEC) == 0 else { throw TranscriptionError.message("无法配置音频流。") }
        var enabled: Int32 = 1
        guard setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw TranscriptionError.message("无法配置音频流。") }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        child.standardInput = input; child.standardOutput = log; child.standardError = log
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock(); try? input.close()
        var feedError: Error?
        do { try feed(output); try output.close() }
        catch { feedError = error; try? output.close(); if child.isRunning { child.terminate() } }
        child.waitUntilExit()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if let feedError { throw feedError }
        guard child.terminationStatus == 0 else {
            let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw TranscriptionError.message("\(stage)失败（代码 \(child.terminationStatus)）。原始录音和已有文字已保留，可以重试。\n\n" + String(details.suffix(1800)))
        }
    }

    private func checkCancelled() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    /// Continuous-recording chapters can be published just before their last
    /// source segment is sealed. Wait off the UI thread, with cancellation,
    /// and never treat a temporarily incomplete head as a damaged recording.
    private func canonicalReader(for url: URL) throws -> CanonicalAudioReader? {
        for attempt in 0..<480 {
            try checkCancelled()
            do { return try CanonicalAudioInput.reader(for: url) }
            catch CanonicalAudioInput.Failure.notReady where attempt < 479 { Thread.sleep(forTimeInterval: 0.25) }
        }
        throw CanonicalAudioInput.Failure.notReady
    }
    private func writeAudio(_ reader: CanonicalAudioReader, start: Int64, end: Int64, to output: FileHandle) throws {
        guard start >= 0, start < end, end <= reader.durationFrames else { throw TranscriptionError.message("音频片段时间无效。") }
        var cursor = start
        while cursor < end {
            try checkCancelled()
            let buffer = try reader.read(startFrame: cursor, count: Int(min(4096, end - cursor)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { throw TranscriptionError.message("无法读取音频片段。") }
            try output.write(contentsOf: Data(bytes: data, count: Int(buffer.frameLength) * MemoryLayout<Float>.size))
            cursor += Int64(buffer.frameLength)
        }
    }
    private func writeClip(_ reader: CanonicalAudioReader, start: Double, end: Double,
                           metadata: [String: Any] = [:], to output: FileHandle) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 30,
              end <= Double(reader.durationFrames) / 16_000 + 0.0001 else { throw TranscriptionError.message("音频片段时间无效。") }
        let first = Int64((start * 16_000).rounded()), last = min(reader.durationFrames, Int64((end * 16_000).rounded()))
        guard last > first, last - first <= 480_000 else { throw TranscriptionError.message("音频片段时间无效。") }
        var header = metadata; header["start"] = start; header["end"] = end; header["frames"] = Int(last - first)
        let data = try JSONSerialization.data(withJSONObject: header)
        guard data.count <= 65_536 else { throw TranscriptionError.message("语音片段信息过大。") }
        var length = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: data); try writeAudio(reader, start: first, end: last, to: output)
    }

    func transcribe(audio: URL, model: URL, executable: URL, language: String, hotwords: [String] = [], context: String = "") throws -> TranscriptionOutput {
        let directory = try temporaryDirectory(prefix: "CoHear-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let segmenter = executable.deletingLastPathComponent().appendingPathComponent("paraformer-live")
        let paraformer = model.deletingLastPathComponent().appendingPathComponent("Paraformer")
        let segments = directory.appendingPathComponent("segments", isDirectory: true)
        let canonical = try canonicalReader(for: audio)
        let manifest = segments.appendingPathComponent("segments.json")
        if let canonical {
            try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
            try runStreaming(segmenter, ["segment-timestamps", paraformer.path, manifest.path], directory: directory, stage: "语音片段检测") {
                try self.writeAudio(canonical, start: 0, end: canonical.durationFrames, to: $0)
            }
        } else {
            let wav = directory.appendingPathComponent("audio.wav")
            try run(URL(fileURLWithPath: "/usr/bin/afconvert"),
                    ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path], directory: directory, stage: "音频格式转换")
            try run(segmenter, ["segment", paraformer.path, wav.path, segments.path], directory: directory, stage: "语音片段检测")
        }
        guard let detected = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]] else {
            throw TranscriptionError.message("语音检测结果无效，原录音已保留。")
        }
        if detected.isEmpty { return TranscriptionOutput(text: "", subtitles: "") }
        let output = directory.appendingPathComponent("transcript.json")
        let hints = directory.appendingPathComponent("hotwords.json")
        try JSONEncoder().encode(HotwordHints(words: hotwords, context: String(context.unicodeScalars.suffix(2000)))).write(to: hints, options: .atomic)
        if let canonical {
            try runStreaming(executable, ["--transcribe-stream", model.path, language, output.path, hints.path], directory: directory, stage: "Qwen语音定稿") { pipe in
                for segment in detected {
                    guard let start = segment["start"] as? Double, let end = segment["end"] as? Double else { throw TranscriptionError.message("语音片段时间无效。") }
                    try self.writeClip(canonical, start: start, end: end, to: pipe)
                }
            }
        } else {
            try run(executable, [model.path, manifest.path, language, output.path, hints.path], directory: directory, stage: "Qwen语音定稿")
        }
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
        let directory = try temporaryDirectory(prefix: "CoHear-speakers-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let turns = directory.appendingPathComponent("turns.json"), aligned = directory.appendingPathComponent("aligned.json")
        if let reader = try canonicalReader(for: audio) {
            onPhase(.diarizing)
            try runStreaming(executable, ["--diarize-stream", sortformer.path, turns.path], directory: directory, stage: "发言人区分") {
                try self.writeAudio(reader, start: 0, end: reader.durationFrames, to: $0)
            }
            onPhase(.aligning)
            try runStreaming(executable, ["--align-stream", aligner.path, turns.path, aligned.path], directory: directory, stage: "发言人与文字对齐") { pipe in
                for paragraph in transcript.paragraphs {
                    guard let start = paragraph.start, let end = paragraph.end else { throw TranscriptionError.message("文字与录音片段不一致，未强行添加发言人。") }
                    try self.writeClip(reader, start: start, end: end, metadata: ["text": paragraph.text, "language": language], to: pipe)
                }
            }
        } else {
            let wav = directory.appendingPathComponent("audio.wav")
            try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path], directory: directory, stage: "录音读取")
            let segments = directory.appendingPathComponent("segments")
            try run(executable.deletingLastPathComponent().appendingPathComponent("paraformer-live"),
                    ["segment", root.appendingPathComponent("Paraformer").path, wav.path, segments.path], directory: directory, stage: "语音片段检测")
            let manifest = segments.appendingPathComponent("segments.json")
            guard let detected = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]] else { throw TranscriptionError.message("语音片段数据无效。") }
            var clips: [[String: Any]] = []
            for paragraph in transcript.paragraphs {
                guard let start = paragraph.start, let end = paragraph.end,
                      var clip = detected.first(where: { item in
                          guard let s = item["start"] as? Double, let e = item["end"] as? Double else { return false }
                          return abs(s - start) < 0.001 && abs(e - end) < 0.001
                      }) else { throw TranscriptionError.message("文字与录音片段不一致，未强行添加发言人。") }
                clip["text"] = paragraph.text; clip["language"] = language; clips.append(clip)
            }
            try JSONSerialization.data(withJSONObject: clips).write(to: manifest, options: .atomic)
            onPhase(.diarizing)
            try run(executable, ["--diarize", sortformer.path, wav.path, turns.path], directory: directory, stage: "发言人区分")
            onPhase(.aligning)
            try run(executable, ["--align-speakers", aligner.path, manifest.path, turns.path, aligned.path], directory: directory, stage: "发言人与文字对齐")
        }
        struct Response: Decodable {
            struct Row: Decodable { let text: String; let separator: String; let start: Double; let end: Double; let speakerIDs: [String] }
            let paragraphs: [Row]
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(contentsOf: aligned))
        guard response.paragraphs.map({ $0.separator + $0.text }).joined() == transcript.text else {
            throw TranscriptionError.message("发言人分段与正文不一致，已保留正文。")
        }
        let rows = try response.paragraphs.map { row in
            guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end >= row.start,
                  row.speakerIDs.count <= 4, row.speakerIDs.allSatisfy({ ["0", "1", "2", "3"].contains($0) }) else {
                throw TranscriptionError.message("发言人时间或编号无效。")
            }
            return TranscriptParagraph(text: row.text, separator: row.separator, start: row.start, end: row.end, speakerIDs: row.speakerIDs)
        }
        return TranscriptReadability.groups(rows).map(\.combined)
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
