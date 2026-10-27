import Foundation

@main struct ContinuousRecordingSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-segment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var closed: [ContinuousSegmentInfo] = []
        let policy = ContinuousSegmentPolicy(maximumSeconds: 10, minimumSeconds: 1, trailingSilenceSeconds: 1, silenceThreshold: 0.01)
        let segmenter = ContinuousRecordingSegmenter(directory: root, policy: policy) { closed.append($0) }
        segmenter.append(Array(repeating: Float(0.2), count: 16_000), at: 0)
        segmenter.append(Array(repeating: Float(0), count: 16_000), at: 1)
        _ = segmenter.finish()
        precondition(closed.count == 1, "连续静音应关闭一个片段")
        precondition(abs(closed[0].duration - 2) < 0.05, "片段应保留语音和静音边界")
        let manifest = try JSONDecoder().decode([ContinuousSegmentInfo].self, from: Data(contentsOf: root.appendingPathComponent("segments.json")))
        precondition(manifest == closed && FileManager.default.fileExists(atPath: closed[0].url.path), "片段和清单必须持久化")
        var short: [ContinuousSegmentInfo] = []
        let bounded = ContinuousRecordingSegmenter(directory: root.appendingPathComponent("bounded"),
            policy: .init(maximumSeconds: 5, minimumSeconds: 3, trailingSilenceSeconds: 1, silenceThreshold: 0.01)) { short.append($0) }
        bounded.append(Array(repeating: Float(0.2), count: 16_000), at: 0)
        bounded.append(Array(repeating: Float(0), count: 16_000), at: 1)
        precondition(short.isEmpty, "短句后的静音不能产生过碎片段")
        bounded.append(Array(repeating: Float(0), count: 16_000), at: 2)
        _ = bounded.finish()
        precondition(short.count == 1 && abs(short[0].duration - 3) < 0.05, "达到最短时长后静音可关闭片段")
        var record = MeetingRecord(title: "全天录音", audioFiles: ["first.wav", "second.wav"], status: .recording)
        record.recordingSessionMode = .continuous
        record.pendingAudioFiles = ["first.wav", "second.wav"]
        let first = TranscriptionOutput(text: "第一句", subtitles: "", paragraphs: [TranscriptParagraph(text: "第一句", start: 0.2, end: 0.8)])
        let second = TranscriptionOutput(text: "第二句", subtitles: "", paragraphs: [TranscriptParagraph(text: "第二句", start: 0.1, end: 0.9)])
        try MeetingRecordingAppend.applyContinuous(first, file: "first.wav", start: 10, to: &record)
        try MeetingRecordingAppend.applyContinuous(second, file: "second.wav", start: 42, to: &record)
        precondition(record.text == "第一句\n\n第二句" && record.pendingAudioFiles.isEmpty, "定稿逐片段提交")
        precondition(record.transcriptParagraphs.map(\.start) == [10.2, 42.1], "时间轴必须保留真实静音间隔")
        let rows = [TranscriptParagraph(text: "第一句", start: 0.2, end: 0.8, speakerIDs: ["0"])]
        try MeetingRecordingAppend.applySpeakerParagraphs(rows, base: first, file: "first.wav", to: &record)
        precondition(record.transcriptParagraphs[0].speakerIDs == ["first.wav:0"], "分人结果只修改对应片段")
        let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
        precondition(restored.recordingSessionMode == .continuous, "会话类型可持久化")
        let library = try MeetingLibrary(root: root.appendingPathComponent("library"))
        var old = MeetingRecord(title: "旧持续录音", status: .recorded)
        old = try library.save(old)
        let metadata = library.directory(for: old.id).appendingPathComponent("meeting.json")
        var fields = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
        fields.removeValue(forKey: "recordingSessionMode")
        try JSONSerialization.data(withJSONObject: fields).write(to: metadata, options: .atomic)
        let legacySegments = library.directory(for: old.id).appendingPathComponent("Capture/Segments")
        try FileManager.default.createDirectory(at: legacySegments, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacySegments.appendingPathComponent("segments.json"))
        let recoveredMode = try library.load(old.id).recordingSessionMode
        precondition(recoveredMode == .continuous, "旧版持续录音清单应恢复会话类型")
        print("PASS: 持续录音按静音切片、片段 WAV 和 segments.json 持久化。无模型推理。")
    }
}
