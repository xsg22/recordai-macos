import AVFoundation
import Foundation

/// Keeps a bounded in-memory audio window and refines only complete Paraformer utterances.
/// Audio and Qwen results are associated by sample time and immutable utterance IDs.
final class LivePreviewRefiner: @unchecked Sendable {
    enum Submission { case queued, retry, discard }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.xsg.talktuck.live-qwen", qos: .utility)
    private let model: URL, executable: URL, scratchRoot: URL
    private let language: String, hotwords: [String], context: String
    private let onResult: ([LiveUtterance], [TranscriptParagraph]) -> Void
    private var samples: [Float] = []
    private var firstSample = 0
    private var outstanding = 0
    private var stopped = false
    private var runningEngine: TranscriptionEngine?
    private let policy = ASRWindowPolicy.load()
    private let sampleRate = 16_000
    private let maximumSamples = 16_000 * 60

    init(model: URL, executable: URL, language: String, hotwords: [String], context: String,
         scratchRoot: URL, onResult: @escaping ([LiveUtterance], [TranscriptParagraph]) -> Void) {
        self.model = model; self.executable = executable; self.language = language
        self.hotwords = hotwords; self.context = context; self.scratchRoot = scratchRoot; self.onResult = onResult
    }

    func append(_ values: [Float]) {
        guard !values.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        samples.append(contentsOf: values)
        if samples.count > maximumSamples {
            let remove = samples.count - maximumSamples
            samples.removeFirst(remove); firstSample += remove
        }
    }

    func submit(rows: [LiveUtterance], sessionOffset: Double) -> Submission {
        guard let first = rows.first, let last = rows.last, rows.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
              first.start >= sessionOffset - 0.01, last.end >= first.start, last.end-first.start <= Double(policy.liveMaximumSeconds) else { return .discard }
        let begin = max(0, Int(((first.start - sessionOffset) * Double(sampleRate)).rounded(.down)))
        let end = max(begin, Int(((last.end - sessionOffset) * Double(sampleRate)).rounded(.up)))
        lock.lock()
        guard !stopped else { lock.unlock(); return .discard }
        guard begin >= firstSample else { lock.unlock(); return .discard }
        guard end <= firstSample + samples.count else { lock.unlock(); return .retry }
        guard outstanding < 2 else { lock.unlock(); return .retry }
        let audio = Array(samples[(begin-firstSample)..<(end-firstSample)])
        guard !audio.isEmpty else { lock.unlock(); return .discard }
        outstanding += 1
        NSLog("TalkTuck live refinement: queued")
        let remove = end - firstSample
        samples.removeFirst(remove); firstSample = end
        lock.unlock()
        worker.async { [self] in
            defer { lock.lock(); outstanding -= 1; lock.unlock() }
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { return }
            let directory = scratchRoot.appendingPathComponent("TalkTuck-live-refine-" + UUID().uuidString, isDirectory: true)
            do {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: scratchRoot.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      FileManager.default.isWritableFile(atPath: scratchRoot.path) else { NSLog("TalkTuck live refinement: scratch unavailable"); return }
                if scratchRoot.path.hasPrefix("/Volumes/") {
                    guard let mountedVolume = try scratchRoot.resourceValues(forKeys: [.volumeURLKey]).volume,
                          mountedVolume.path.hasPrefix("/Volumes/") else { NSLog("TalkTuck live refinement: volume unavailable"); return }
                }
                // Never recreate a missing parent or a disconnected volume's mount point.
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("audio.wav")
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
                      let target = buffer.floatChannelData?.pointee else { return }
                buffer.frameLength = AVAudioFrameCount(audio.count)
                audio.withUnsafeBufferPointer { if let base = $0.baseAddress { target.update(from: base, count: audio.count) } }
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false); try file.write(from: buffer) }
                let engine = TranscriptionEngine(temporaryRoot: directory)
                lock.lock(); if stopped { lock.unlock(); return }; runningEngine = engine; lock.unlock()
                defer { lock.lock(); runningEngine = nil; lock.unlock() }
                NSLog("TalkTuck live refinement: recognition started")
                let output = try engine.transcribe(audio: url, model: model, executable: executable, language: language, hotwords: hotwords, context: context, offlineWindows:true, windowSeconds:policy.liveMaximumSeconds, overlapSeconds:0)
                lock.lock(); let allowed = !stopped; lock.unlock()
                if allowed && !output.paragraphs.isEmpty { NSLog("TalkTuck live refinement: recognition completed"); onResult(rows, output.paragraphs) }
                else if allowed { NSLog("TalkTuck live refinement: empty result") }
            } catch { NSLog("TalkTuck live refinement: processing failed code=%ld", (error as NSError).code) }
        }
        return .queued
    }

    func cancel() {
        lock.lock(); stopped = true; samples.removeAll(); let engine = runningEngine; lock.unlock()
        engine?.cancel()
    }

    /// The ASR can repeat its vocabulary prompt as a comma-separated sentence.
    /// Prefer the existing preview to injecting a list not supported by the original audio transcript.
    static func isPlausible(text: String, original: [LiveUtterance], hotwords: [String]) -> Bool {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return false }
        let reference = original.map(\.text).joined(separator: " ").lowercased()
        let terms = Set(hotwords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { $0.count >= 2 })
        let separators = CharacterSet(charactersIn: "，,、;；。.!！？?：:\n\r")
        var consecutive: [String] = []
        for part in result.lowercased().components(separatedBy: separators) {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if terms.contains(item) {
                if !consecutive.contains(item) { consecutive.append(item) }
                if consecutive.count >= 3 && consecutive.filter({ reference.contains($0) }).count < 3 { return false }
            } else { consecutive.removeAll() }
        }
        return true
    }

    /// Match Qwen speech intervals against the original Paraformer utterances. Unmatched,
    /// questionable or overlapping output is ignored, preserving the original rows.
    static func replacing(rows: [LiveUtterance], original: [LiveUtterance], refined: [TranscriptParagraph], hotwords: [String]) -> [LiveUtterance]? {
        guard let originalFirst = original.first, let first = rows.firstIndex(where: { $0.id == originalFirst.id }),
              first + original.count <= rows.count,
              Array(rows[first..<(first + original.count)]) == original else { return nil }
        struct Assignment { var start: Int; var end: Int; var text: String }
        var assignments: [Assignment] = []
        for item in refined {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = item.start, let end = item.end, start.isFinite, end.isFinite, start >= 0, end > start,
                  end <= (original.last!.end - originalFirst.start) + 0.5, !text.isEmpty else { continue }
            let absoluteStart = originalFirst.start + start, absoluteEnd = originalFirst.start + end
            let indexes = original.indices.filter { index in
                let row = original[index]
                let overlap = max(0, min(row.end, absoluteEnd) - max(row.start, absoluteStart))
                return overlap >= min(0.15, max(0.05, (row.end - row.start) * 0.2))
            }
            guard let lower = indexes.first, let upper = indexes.last,
                  isPlausible(text: text, original: Array(original[lower...upper]), hotwords: hotwords) else { continue }
            if let last = assignments.last, lower <= last.end {
                if lower == last.start && upper == last.end { assignments[assignments.count - 1].text += "\n" + text }
                else { return nil } // Ambiguous overlap: keep all original text.
            } else { assignments.append(Assignment(start: lower, end: upper, text: text)) }
        }
        guard !assignments.isEmpty else { return nil }
        var output = rows
        for item in assignments.reversed() {
            let start = first + item.start, end = first + item.end
            let merged = LiveUtterance(text: item.text, start: rows[start].start, end: rows[end].end)
            output.replaceSubrange(start...end, with: [merged])
        }
        return output
    }
}
