import Foundation
import AVFoundation

@main struct RecordingAppendSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-append-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args[3])
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let engine = TranscriptionEngine()
        var meeting = MeetingRecord(title: "合成会议续录测试", notes: "原始手稿", summary: "已有摘要", status: .recorded)
        let id = meeting.id
        _ = try library.importAudio(source, into: &meeting, recordingDuration: duration)
        let first = try engine.transcribe(audio: source, model: URL(fileURLWithPath: args[2]), executable: URL(fileURLWithPath: args[1]), language: "zh")
        try MeetingRecordingAppend.apply(outputs: [first], files: meeting.pendingAudioFiles, durations: [duration], appending: true, to: &meeting)
        meeting.status = .completed; meeting.previewText = "第一段实时历史"
        meeting.text += "\n用户校正的原文"
        _ = try library.save(meeting)
        let oldText = meeting.text, oldSubtitles = meeting.subtitles
        _ = try library.importAudio(source, into: &meeting, recordingDuration: duration)
        let pending = meeting.pendingAudioFiles
        // 模拟停止后取消/重启；待处理片段必须仍能被发现，原稿不得变化。
        meeting = try MeetingLibrary(root: root).load(id)
        precondition(meeting.pendingAudioFiles == pending && meeting.text == oldText)
        precondition(meeting.audioFiles.count == 2 && meeting.notes == "原始手稿")
        let second = try engine.transcribe(audio: source, model: URL(fileURLWithPath: args[2]), executable: URL(fileURLWithPath: args[1]), language: "zh")
        try MeetingRecordingAppend.apply(outputs: [second], files: pending, durations: [duration], appending: true, to: &meeting)
        meeting.status = .completed; _ = try library.save(meeting)
        let saved = try library.load(id)
        precondition(saved.id == id && saved.text == oldText + "\n\n" + second.text)
        precondition(saved.subtitles.hasPrefix(oldSubtitles) && saved.subtitles.contains("00:00:14,"))
        precondition(saved.audioFiles.count == 2 && saved.pendingAudioFiles.isEmpty)
        precondition(saved.notes == "原始手稿" && saved.summary == "已有摘要" && saved.previewText == "第一段实时历史")
        precondition(abs(saved.duration - duration * 2) < 0.01)
        let savedURLs = try library.audioURLs(for: saved)
        precondition(savedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        var duplicate = saved
        do {
            try MeetingRecordingAppend.apply(outputs: [second], files: pending, durations: [duration], appending: true, to: &duplicate)
            fatalError("已成功片段不得重复追加")
        } catch { precondition(duplicate == saved) }
        let shifted = try MeetingRecordingAppend.appendSRT("1\n00:00:00,000 --> 00:00:01,250\n新增字幕\n\n", to: "1\n00:00:00,000 --> 00:00:02,000\n原字幕\n\n", offset: 65.5)
        precondition(shifted.contains("2\n00:01:05,500 --> 00:01:06,750"))
        print("PASS: 真实中文两段转录、同会议ID、原文校正保留、片段回放路径、时长累加、字幕时间轴、重启待处理恢复与重复追加保护。仅临时合成资料。")
    }
}
