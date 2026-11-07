import Foundation
import AVFoundation
import Darwin

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

private struct HotwordHints: Encodable { let words: [String]; let context: String }

struct TranscriptionOutput: Codable, Sendable {
    let text: String
    let subtitles: String
    var paragraphs: [TranscriptParagraph] = []
    func readingFallback(hotwords: [String] = []) -> TranscriptionOutput {
        TranscriptionOutput(text: text, subtitles: subtitles, paragraphs: TranscriptReadability.fallback(text, hotwords: hotwords))
    }
}

/// 每次任务拥有独立进程和临时目录；取消不会影响其他任务或留下半成品。
final class TranscriptionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let temporaryRoot: URL
    private let evidenceRoot: URL?
    private let memoryLimitMB: Int?
    private var process: Process?
    private var cancelled = false

    init(temporaryRoot: URL? = nil, evidenceRoot: URL? = nil, memoryLimitMB: Int? = nil) {
        self.evidenceRoot = evidenceRoot
        self.memoryLimitMB = memoryLimitMB
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
        let heavy = executable.lastPathComponent == "qwen-asr"
        if heavy { InferenceGate.enter() }; defer { if heavy { InferenceGate.leave() } }
        let logURL = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryRoot.path
        environment["TALKTUCK_INFERENCE_LOCK"] = InferenceGate.coordinationPath
        if let memoryLimitMB { environment["TALKTUCK_ASR_MEMORY_MB"] = String(memoryLimitMB) }
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        child.waitUntilExit()
        if child.terminationStatus != 0 { try? captureEvidence(logURL,name:"worker-failure-"+logURL.lastPathComponent) }
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
        InferenceGate.enter(); defer { InferenceGate.leave() }
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
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryRoot.path
        environment["TALKTUCK_INFERENCE_LOCK"] = InferenceGate.coordinationPath
        if let memoryLimitMB { environment["TALKTUCK_ASR_MEMORY_MB"] = String(memoryLimitMB) }
        child.environment = environment
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
        if child.terminationStatus != 0 { try? captureEvidence(logURL,name:"worker-failure-"+logURL.lastPathComponent) }
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if let feedError {
            let ns = feedError as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            let broken = (ns.domain == NSPOSIXErrorDomain && ns.code == Int(EPIPE)) || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EPIPE))
            if broken, let details = try? String(contentsOf: logURL, encoding: .utf8), !details.isEmpty {
                throw TranscriptionError.message("\(stage)失败（代码 \(child.terminationStatus)）。原始录音和已有文字已保留，可以重试。\n\n" + String(details.suffix(1800)))
            }
            throw feedError
        }
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
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= Double(ASRWindowPolicy.maximumAlignmentSeconds),
              end <= Double(reader.durationFrames) / 16_000 + 0.0001 else { throw TranscriptionError.message("音频片段时间无效。") }
        let first = Int64((start * 16_000).rounded()), last = min(reader.durationFrames, Int64((end * 16_000).rounded()))
        guard last > first, last - first <= Int64(ASRWindowPolicy.maximumAlignmentSeconds * 16_000) else { throw TranscriptionError.message("音频片段时间无效。") }
        var header = metadata; header["start"] = start; header["end"] = end; header["frames"] = Int(last - first)
        let data = try JSONSerialization.data(withJSONObject: header)
        guard data.count <= 65_536 else { throw TranscriptionError.message("语音片段信息过大。") }
        var length = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: data); try writeAudio(reader, start: first, end: last, to: output)
    }

    // Offline recognition keeps quiet speech: only near-digital silence is skipped.
    private func fixedWindowTranscribe(audio: URL, model: URL, executable: URL, language: String,
                                       hotwords: [String], context: String, directory: URL, windowSeconds:Int, overlapSeconds:Int) throws -> TranscriptionOutput {
        guard windowSeconds > 0, windowSeconds <= ASRWindowPolicy.maximumASRSeconds, overlapSeconds >= 0, overlapSeconds < windowSeconds else { throw TranscriptionError.message("音频片段时间无效。") }
        let canonical = try canonicalReader(for: audio)
        var wave: AVAudioFile?
        if canonical == nil {
            let normalized = directory.appendingPathComponent("audio.wav")
            try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, normalized.path], directory: directory, stage: "音频格式转换")
            wave = try AVAudioFile(forReading: normalized)
            guard wave?.processingFormat.sampleRate == 16_000, wave?.processingFormat.channelCount == 1 else { throw TranscriptionError.message("音频格式无效。") }
        }
        let frames = canonical?.durationFrames ?? wave!.length
        func read(_ start: Int64, _ count: Int) throws -> AVAudioPCMBuffer {
            try checkCancelled()
            if let canonical { return try canonical.read(startFrame: start, count: count) }
            guard let wave, let buffer = AVAudioPCMBuffer(pcmFormat: wave.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { throw TranscriptionError.message("无法读取音频。") }
            wave.framePosition = start; try wave.read(into: buffer, frameCount: AVAudioFrameCount(count)); return buffer
        }
        var windows: [(Int64, Int64)] = []; var start: Int64 = 0
        while start < frames {
            let end = min(frames, start + Int64(windowSeconds * 16_000))
            var cursor = start; var peak: Float = 0
            while cursor < end {
                let b = try read(cursor, Int(min(4096, end - cursor)))
                guard b.frameLength > 0, let values = b.floatChannelData?[0] else { throw TranscriptionError.message("无法读取音频片段。") }
                for i in 0..<Int(b.frameLength) { peak = max(peak, abs(values[i])) }
                cursor += Int64(b.frameLength)
            }
            if peak > 2.0 / 32768.0 { windows.append((start, end)) }
            if end == frames { break }; start += Int64((windowSeconds-overlapSeconds) * 16_000)
        }
        if windows.isEmpty { return TranscriptionOutput(text: "", subtitles: "") }
        let output = directory.appendingPathComponent("transcript.json"), hints = directory.appendingPathComponent("hotwords.json")
        try JSONEncoder().encode(HotwordHints(words: hotwords, context: String(context.unicodeScalars.suffix(2000)))).write(to: hints, options: .atomic)
        try runStreaming(executable, ["--transcribe-stream", model.path, language, output.path, hints.path], directory: directory, stage: "Qwen语音定稿") { pipe in
            for (start, end) in windows {
                let header: [String: Any] = ["start": Double(start) / 16_000, "end": Double(end) / 16_000, "frames": Int(end-start)]
                let data = try JSONSerialization.data(withJSONObject: header); var length = UInt32(data.count).littleEndian
                try withUnsafeBytes(of: &length) { try pipe.write(contentsOf: Data($0)) }; try pipe.write(contentsOf: data)
                var cursor = start
                while cursor < end {
                    let b = try read(cursor, Int(min(4096, end-cursor)))
                    guard b.frameLength > 0, let values = b.floatChannelData?[0] else { throw TranscriptionError.message("无法读取音频片段。") }
                    try pipe.write(contentsOf: Data(bytes: values, count: Int(b.frameLength) * MemoryLayout<Float>.size)); cursor += Int64(b.frameLength)
                }
            }
        }
        try captureEvidence(output, name: "recognition.json")
        let segments = try JSONDecoder().decode(QwenOutput.self, from: Data(contentsOf: output)).segments
        guard segments.count == windows.count else { throw TranscriptionError.message("定稿未覆盖全部音频片段，原录音已保留。") }
        var paragraphs: [TranscriptParagraph] = []; var subtitles: [String] = []; var previous = ""; var previousEnd: Double = -1
        for (i, s) in segments.enumerated() {
            let expected = windows[i]; let lo = Double(expected.0)/16_000, hi = Double(expected.1)/16_000
            guard s.start.isFinite, s.end.isFinite, abs(s.start-lo)<0.001, abs(s.end-hi)<0.001 else { throw TranscriptionError.message("转录时间不一致，原录音已保留。") }
            let original = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = lo < previousEnd ? Self.removeExactOverlap(previous, original) : original
            let segmentStart = text == original ? lo : max(lo, min(previousEnd, hi))
            previous = original; previousEnd = hi
            if !text.isEmpty {
                subtitles.append("\(subtitles.count + 1)\n\(Self.timestamp(segmentStart)) --> \(Self.timestamp(hi))\n\(text)")
                let parts = s.alignmentParts ?? [QwenOutput.Part(text: original, start: lo, end: hi)]
                if s.alignmentParts != nil {
                    guard !parts.isEmpty, parts.map(\.text).joined() == original,
                          parts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= lo && $0.end <= hi + 0.001 && $0.end > $0.start && $0.end - $0.start <= Double(ASRWindowPolicy.maximumAlignmentSeconds) }) else {
                        throw TranscriptionError.message("时间戳分段与定稿正文不一致，未保存部分结果。")
                    }
                    for pair in zip(parts, parts.dropFirst()) where pair.1.start < pair.0.start { throw TranscriptionError.message("时间戳分段顺序无效。") }
                }
                var remaining = original.count - text.count
                var firstPart = true
                for part in parts {
                    let count = min(remaining, part.text.count); remaining -= count
                    let body = String(part.text.dropFirst(count))
                    guard !body.isEmpty else { continue }
                    paragraphs.append(TranscriptParagraph(text: body, separator: paragraphs.isEmpty ? "" : firstPart ? "\n" : "", start: max(part.start, segmentStart), end: part.end))
                    firstPart = false
                }
                guard remaining == 0 else { throw TranscriptionError.message("定稿重叠分段不完整。") }
            }
        }
        return TranscriptionOutput(text: paragraphs.map { $0.separator + $0.text }.joined(), subtitles: subtitles.isEmpty ? "" : subtitles.joined(separator: "\n\n") + "\n\n", paragraphs: paragraphs)
    }
    // Only remove strongly matching overlap; short or uncertain repetitions remain.
    static func removeExactOverlap(_ previous: String, _ current: String) -> String {
        let aa = Array(previous.filter { $0.isLetter || $0.isNumber }.lowercased())
        let indexed = current.indices.filter { current[$0].isLetter || current[$0].isNumber }
        let bb = Array(String(indexed.map { current[$0] }).lowercased())
        let limit = min(65, aa.count, bb.count)
        guard limit >= 6 else { return current }
        var bestScore: Double = 0; var bestCount = 0
        for n in 6...limit {
            for m in max(6, n-5)...min(bb.count, n+5) {
                let left = Array(aa.suffix(n)), right = Array(bb.prefix(m))
                var previousRow = Array(repeating: 0, count: m+1)
                for x in left {
                    var row = Array(repeating: 0, count: m+1)
                    for j in 1...m { row[j] = x == right[j-1] ? previousRow[j-1]+1 : max(previousRow[j], row[j-1]) }
                    previousRow = row
                }
                let ratio = 2.0 * Double(previousRow[m]) / Double(n+m)
                let score = ratio * Double(min(n,m))
                if ratio >= 0.9 && score > bestScore { bestScore = score; bestCount = m }
            }
        }
        guard bestCount > 0 && bestCount <= indexed.count else { return current }
        var end = current.index(after: indexed[bestCount-1])
        while end < current.endIndex && !current[end].isLetter && !current[end].isNumber { end = current.index(after: end) }
        return String(current[end...])
    }

    /// A decoder-limit failure must not publish truncated text. Retry only
    /// this unacknowledged batch, with a finite smaller-window sequence.
    func transcribeBatch(audio:URL,model:URL,executable:URL,language:String,hotwords:[String],context:String,
                         windowSeconds:Int,onRecovery:(Int)->Void = {_ in}) throws -> TranscriptionOutput {
        var seen=Set<Int>();var last:Error=TranscriptionError.message("转录未完成。")
        for seconds in [windowSeconds,120,60,24] where seconds<=windowSeconds && seen.insert(seconds).inserted {
            try checkCancelled()
            do {
                return try transcribe(audio:audio,model:model,executable:executable,language:language,hotwords:hotwords,context:context,
                    offlineWindows:true,windowSeconds:seconds,overlapSeconds:seconds==windowSeconds ? 0:3)
            } catch {
                last=error;try checkCancelled()
                guard Self.isRecoverableWindowFailure(error) else { throw error }
                onRecovery(seconds)
            }
        }
        throw last
    }
    static func isRecoverableWindowFailure(_ error:Error)->Bool {
        let message=error.localizedDescription.lowercased()
        return ["transcript token limit reached","memory limit","out of memory","failed to allocate"].contains{message.contains($0)}
    }
    func transcribe(audio: URL, model: URL, executable: URL, language: String, hotwords: [String] = [], context: String = "", offlineWindows: Bool = false, windowSeconds:Int? = nil, overlapSeconds:Int? = nil) throws -> TranscriptionOutput {
        let directory = try temporaryDirectory(prefix: "CoHear-")
        defer { try? FileManager.default.removeItem(at: directory) }
        if offlineWindows { return try fixedWindowTranscribe(audio: audio, model: model, executable: executable, language: language, hotwords: hotwords, context: context, directory: directory, windowSeconds:windowSeconds ?? ASRWindowPolicy.load(language:language).offlineSeconds, overlapSeconds:overlapSeconds ?? ASRWindowPolicy.load().overlapSeconds) }
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
    func analyzeSpeakers(audio: URL, model: URL, executable: URL, transcript: TranscriptionOutput, language: String = "zh", hotwords: [String] = [],
                         speakerCheckpoint: URL? = nil,
                         onPhase: @escaping @Sendable (TranscriptPhase) -> Void = { _ in }) throws -> [TranscriptParagraph] {
        if transcript.paragraphs.isEmpty && speakerCheckpoint == nil { return [] }
        let root = model.deletingLastPathComponent()
        let sortformer = root.appendingPathComponent("Sortformer"), aligner = root.appendingPathComponent("QwenAligner")
        guard FileManager.default.fileExists(atPath: sortformer.appendingPathComponent("model.safetensors").path) else {
            throw TranscriptionError.message("发言人模型缺失，请在设置中重新下载。正文已保存。")
        }
        let directory = try temporaryDirectory(prefix: "CoHear-speakers-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let turns = directory.appendingPathComponent("turns.json"), aligned = directory.appendingPathComponent("aligned.json")
        if let reader = try canonicalReader(for: audio) {
            onPhase(.diarizing)
            let command = speakerCheckpoint.map { ["--diarize-stream-checkpoint", sortformer.path, turns.path, $0.path] } ?? ["--diarize-stream", sortformer.path, turns.path]
            try runStreaming(executable, command, directory: directory, stage: "发言人区分") {
                try self.writeAudio(reader, start: 0, end: reader.durationFrames, to: $0)
            }
            try captureEvidence(turns, name: "diarization.json")
            if transcript.paragraphs.isEmpty { return [] }
            guard FileManager.default.fileExists(atPath: aligner.appendingPathComponent("model.safetensors").path) else { throw TranscriptionError.message("时间对齐模型缺失，正文和发言人分析状态已保留。") }
            guard transcript.paragraphs.allSatisfy({ ($0.end ?? 0) - ($0.start ?? 0) <= Double(ASRWindowPolicy.maximumAlignmentSeconds) }) else {
                throw TranscriptionError.message("定稿正文已保存，时间戳分段暂未确认；可以重新转录后重试。")
            }
            onPhase(.aligning)
            try runStreaming(executable, ["--align-stream", aligner.path, turns.path, aligned.path], directory: directory, stage: "发言人与文字对齐") { pipe in
                for paragraph in transcript.paragraphs {
                    guard let start = paragraph.start, let end = paragraph.end else { throw TranscriptionError.message("文字与录音片段不一致，未强行添加发言人。") }
                    try self.writeClip(reader, start: start, end: end, metadata: ["text": paragraph.text, "language": language, "separator": paragraph.separator, "hotwords": hotwords], to: pipe)
                }
            }
        } else {
            let wav = directory.appendingPathComponent("audio.wav")
            try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path], directory: directory, stage: "录音读取")
            let segments = directory.appendingPathComponent("segments", isDirectory: true)
            try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
            let manifest = segments.appendingPathComponent("segments.json")
            let reader = try AVAudioFile(forReading: wav)
            guard reader.processingFormat.sampleRate == 16_000, reader.processingFormat.channelCount == 1 else { throw TranscriptionError.message("音频格式无效。") }
            onPhase(.diarizing)
            let command = speakerCheckpoint.map { ["--diarize-checkpoint", sortformer.path, wav.path, turns.path, $0.path] } ?? ["--diarize", sortformer.path, wav.path, turns.path]
            try run(executable, command, directory: directory, stage: "发言人区分")
            try captureEvidence(turns, name: "diarization.json")
            if transcript.paragraphs.isEmpty { return [] }
            guard FileManager.default.fileExists(atPath: aligner.appendingPathComponent("model.safetensors").path) else { throw TranscriptionError.message("时间对齐模型缺失，正文和发言人分析状态已保留。") }
            guard transcript.paragraphs.allSatisfy({ ($0.end ?? 0) - ($0.start ?? 0) <= Double(ASRWindowPolicy.maximumAlignmentSeconds) }) else {
                throw TranscriptionError.message("定稿正文已保存，时间戳分段暂未确认；可以重新转录后重试。")
            }
            var clips: [[String: Any]] = []
            for (index, paragraph) in transcript.paragraphs.enumerated() {
                try checkCancelled()
                guard let start = paragraph.start, let end = paragraph.end, start.isFinite, end.isFinite,
                      start >= 0, end > start, end-start <= Double(ASRWindowPolicy.maximumAlignmentSeconds), end <= Double(reader.length)/16_000 + 0.0001 else {
                    throw TranscriptionError.message("文字与录音片段不一致，未强行添加发言人。")
                }
                let first = Int64((start*16_000).rounded()), last = min(reader.length, Int64((end*16_000).rounded()))
                guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(last-first)) else { throw TranscriptionError.message("无法读取音频片段。") }
                reader.framePosition = first; try reader.read(into: buffer, frameCount: AVAudioFrameCount(last-first))
                guard Int64(buffer.frameLength) == last-first else { throw TranscriptionError.message("音频片段读取不完整。") }
                let path = segments.appendingPathComponent("\(index).wav")
                let writer = try AVAudioFile(forWriting: path, settings: reader.fileFormat.settings, commonFormat: reader.processingFormat.commonFormat, interleaved: reader.processingFormat.isInterleaved)
                try writer.write(from: buffer)
                clips.append(["audio": path.path, "start": start, "end": end, "text": paragraph.text, "language": language, "separator": paragraph.separator, "hotwords": hotwords])
            }
            try JSONSerialization.data(withJSONObject: clips).write(to: manifest, options: .atomic)
            onPhase(.aligning)
            try run(executable, ["--align-speakers", aligner.path, manifest.path, turns.path, aligned.path], directory: directory, stage: "发言人与文字对齐")
        }
        try captureEvidence(aligned, name: "alignment.json")
        return try Self.decodeSpeakerParagraphs(Data(contentsOf: aligned), text: transcript.text)
    }

    func cropSpeakerEvidence(at directory: URL, trimBefore: Double, previousText: String, executable: URL, hotwords: [String] = []) throws -> TranscriptionOutput {
        guard trimBefore.isFinite, trimBefore>=0,trimBefore<=3.001 else { throw TranscriptionError.message("音频片段时间无效。") }
        let prior=directory.appendingPathComponent("prior.txt"),out=directory.appendingPathComponent("owned.json")
        try JSONEncoder().encode(HotwordHints(words:hotwords,context:previousText)).write(to:prior,options:.atomic)
        try run(executable,["--crop-speakers",directory.appendingPathComponent("alignment.json").path,directory.appendingPathComponent("diarization.json").path,String(trimBefore),prior.path,out.path],directory:directory,stage:"核对分批边界")
        let data=try Data(contentsOf:out)
        guard let value=try JSONSerialization.jsonObject(with:data)as? [String:Any],let text=value["text"]as? String else { throw TranscriptionError.message("定稿边界数据无效。") }
        return TranscriptionOutput(text:text,subtitles:"",paragraphs:try Self.decodeSpeakerParagraphs(data,text:text))
    }

    /// Retry only the left seam's alignment. Recognition, global voice state
    /// and the remainder of the batch are immutable inputs, not rerun work.
    func repairProgressiveSeam(audio:URL,model:URL,executable:URL,directory:URL,trimBefore:Double,previousText:String,language:String,hotwords:[String]) throws -> TranscriptionOutput {
        guard trimBefore>0,let reader=try canonicalReader(for:audio),
              let source=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("alignment.json")))as? [String:Any],
              let words=source["alignedWords"]as? [[String:Any]] else { throw BalancedAudioError.invalidManifest }
        var lastError:Error=TranscriptionError.message("接缝归属尚未确认，原音和两侧候选均已保留。")
        for seconds in [12.0,24.0] {
            try checkCancelled()
            let count=words.prefix{($0["end"]as? Double ?? .infinity)<=seconds}.count
            guard count>0,count<words.count,let end=words[count-1]["end"]as? Double,end>trimBefore+1,
                  let next=words[count]["start"]as? Double,next>=end-0.15 else { continue }
            let attempt=directory.appendingPathComponent("seam-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:attempt,withIntermediateDirectories:false)
            try FileManager.default.copyItem(at:directory.appendingPathComponent("diarization.json"),to:attempt.appendingPathComponent("diarization.json"))
            let prefix=words.prefix(count).map{($0["separator"]as? String ?? "")+($0["text"]as? String ?? "")}.joined()
            do {
                let aligned=attempt.appendingPathComponent("prefix.json")
                try runStreaming(executable,["--align-stream",model.deletingLastPathComponent().appendingPathComponent("QwenAligner").path,attempt.appendingPathComponent("diarization.json").path,aligned.path],directory:attempt,stage:"重试接缝时间对齐") { pipe in
                    try self.writeClip(reader,start:0,end:end,metadata:["text":prefix,"language":language,"separator":"","hotwords":hotwords],to:pipe)
                }
                try run(executable,["--splice-seam",directory.appendingPathComponent("alignment.json").path,aligned.path,String(count),String(end),attempt.appendingPathComponent("alignment.json").path],directory:attempt,stage:"核对接缝文字保全")
                let result=try cropSpeakerEvidence(at:attempt,trimBefore:trimBefore,previousText:previousText,executable:executable,hotwords:hotwords)
                try BalancedAudioIO.save(["alignedSeconds":end,"prefixWords":Double(count),"recognitionReruns":0,"diarizationReruns":0],to:attempt.appendingPathComponent("repair.json"))
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { lastError=error }
        }
        throw lastError
    }

    private static func decodeSpeakerParagraphs(_ data: Data, text: String) throws -> [TranscriptParagraph] {
        struct Response: Decodable {
            struct Row: Decodable { let text: String; let separator: String; let start: Double; let end: Double; let speakerIDs: [String]; let timingUncertain: Bool?; let alignedStart: Double?; let alignedEnd: Double? }
            let paragraphs: [Row]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.paragraphs.map({ $0.separator + $0.text }).joined() == text else {
            throw TranscriptionError.message("发言人分段与正文不一致，已保留正文。")
        }
        let rows = try response.paragraphs.map { row in
            guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end >= row.start,
                  row.speakerIDs.count <= 4, row.speakerIDs.allSatisfy({ ["0", "1", "2", "3"].contains($0) }) else {
                throw TranscriptionError.message("发言人时间或编号无效。")
            }
            let timed = row.end > row.start && row.timingUncertain != true
            if row.alignedStart != nil || row.alignedEnd != nil {
                guard let a = row.alignedStart, let b = row.alignedEnd, a.isFinite, b.isFinite,
                      a >= row.start, b <= row.end, b > a else { throw TranscriptionError.message("发言人时间或编号无效。") }
            }
            return TranscriptParagraph(text: row.text, separator: row.separator, start: timed ? row.start : nil, end: timed ? row.end : nil, speakerIDs: row.speakerIDs, alignedStart: timed ? nil : row.alignedStart, alignedEnd: timed ? nil : row.alignedEnd)
        }
        for pair in zip(response.paragraphs, response.paragraphs.dropFirst()) where pair.1.start < pair.0.start - 0.15 {
            throw TranscriptionError.message("时间戳分段顺序不一致，已保留正文。")
        }
        return TranscriptReadability.groups(rows).map(\.combined)
    }

    private func captureEvidence(_ source: URL, name: String) throws {
        guard let evidenceRoot else { return }
        try FileManager.default.copyItem(at: source, to: evidenceRoot.appendingPathComponent(name))
    }

    private struct QwenOutput: Decodable {
        struct Part: Decodable { let text: String; let start: Double; let end: Double }
        struct Segment: Decodable { let text: String; let start: Double; let end: Double; let alignmentParts: [Part]?; let alignmentIssue: String? }
        let segments: [Segment]
    }
    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
