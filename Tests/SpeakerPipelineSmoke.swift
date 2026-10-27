import Foundation
import AVFoundation

@main struct SpeakerPipelineSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        let exe = URL(fileURLWithPath: args[1]), model = URL(fileURLWithPath: args[2]), source = URL(fileURLWithPath: args[3])
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let base = try TranscriptionEngine().transcribe(audio: source, model: model, executable: exe, language: "zh")
        precondition(base.text.contains("会议") && !base.paragraphs.isEmpty)
        let rows = try TranscriptionEngine().analyzeSpeakers(audio: source, model: model, executable: exe, transcript: base)
        precondition(rows.map { $0.separator + $0.text }.joined() == base.text, "分人不能删字或改字")
        let speakers = Set(rows.flatMap(\.speakerIDs))
        precondition(speakers.count == 2, "双声音测试应区分两位发言人")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-speaker-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(title: "双人合成会议", notes: "保留手写决定", status: .recorded)
        _ = try library.importAudio(source, into: &record, recordingDuration: duration)
        let files = record.pendingAudioFiles
        try MeetingRecordingAppend.apply(outputs: [base], files: files, durations: [duration], appending: true, to: &record)
        record.status = .completed; record.speakerAnalysisStatus = .processing
        _ = try library.save(record)
        precondition(record.pendingAudioFiles.isEmpty && record.text == base.text)
        let recovered = try MeetingLibrary(root: root).load(record.id)
        precondition(recovered.status == .completed && recovered.speakerAnalysisStatus == .cancelled && recovered.text == base.text)
        try MeetingRecordingAppend.applySpeakerParagraphs(rows, base: base, file: files[0], to: &record)
        record.speakerAnalysisStatus = .completed
        precondition(record.hasCurrentParagraphs && record.text == base.text && record.notes == "保留手写决定")
        precondition(Set(record.transcriptParagraphs.flatMap(\.speakerIDs)).count == 2)
        let first = record.transcriptParagraphs.compactMap(\.localStart).first!
        precondition(first >= 0 && first < duration)
        _ = try library.save(record)
        let saved = try library.load(record.id)
        precondition(saved == record || saved.transcriptParagraphs == record.transcriptParagraphs)
        let md = library.markdown(for: saved)
        precondition(md.contains("发言人 1") && md.contains("发言人 2") && md.contains("会议客户端"))
        let report = URL(fileURLWithPath: args[4])
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: report)
        print("PASS: 真Qwen→Sortformer双声音→逐词对齐，完整保留原文、两位发言人、分段持久化、发言人Markdown、音频定位、分析中断正文仍可用。仅合成会议。")
    }
}
