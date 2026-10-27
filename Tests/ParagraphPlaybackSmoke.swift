import AVFoundation
import Foundation

@main struct ParagraphPlaybackSmoke {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cohear-sentence-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("silence.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000
            for i in 0..<32_000 { buffer.floatChannelData![0][i] = 0 }
            try file.write(from: buffer)
        }
        let library = try MeetingLibrary(root: root.appendingPathComponent("Library"))
        var record = MeetingRecord(title: "单句回放", text: "第一句。\n第二句。", status: .recorded)
        _ = try library.importAudio(source, into: &record, recordingDuration: 2)
        _ = try library.importAudio(source, into: &record, recordingDuration: 2)
        record.status = .completed; record.pendingAudioFiles = []
        let first = TranscriptParagraph(text: "第一句。", start: 0.1, end: 0.3, audioFile: record.audioFiles[0], localStart: 0.1)
        let second = TranscriptParagraph(text: "第二句。", separator: "\n", start: 2.5, end: 2.75, audioFile: record.audioFiles[1], localStart: 0.5)
        record.transcriptParagraphs = [first, second]
        _ = try library.save(record)
        let state = AppState(storageURL: library.root, connectionNamespace: "paragraph-test-")
        state.playbackVolume = 0 // 真播放器测试但全静音，不干扰会议。
        state.select(record.id)
        precondition(state.canPlayTranscriptParagraph(second))
        state.playTranscriptParagraph(second)
        precondition(state.playing && state.playingParagraphID == second.id && state.playbackSegment == 1)
        precondition(abs(state.playbackTime - 0.5) < 0.05, "续录必须用局部时间")
        for _ in 0..<100 where state.playing { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(!state.playing && state.playingParagraphID == nil)
        precondition(abs(state.playbackTime - 0.75) < 0.001, "句尾暂停并保留定位")
        state.playTranscriptParagraph(second)
        state.playTranscriptParagraph(first)
        precondition(state.playingParagraphID == first.id && state.playbackSegment == 0)
        for _ in 0..<100 where state.playing { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(abs(state.playbackTime - 0.3) < 0.001, "快速切句不能被旧边界停止")
        state.togglePlayback()
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(state.playing && state.playbackTime > 0.4 && state.playingParagraphID == nil, "普通播放应连续")
        state.stopPlayback()
        state.playTranscriptParagraph(first)
        state.seek(0.8)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(state.playing && state.playbackTime > 0.8 && state.playingParagraphID == nil, "手动拖动退出单句模式")
        state.stopPlayback()
        var invalid = first; invalid.end = nil
        precondition(!state.canPlayTranscriptParagraph(invalid))
        invalid.end = .nan
        precondition(TranscriptPlaybackRange(paragraph: invalid, record: record) == nil)
        var missingDurations = record; missingDurations.audioDurations = [:]
        var fallback = second; fallback.localStart = nil
        precondition(TranscriptPlaybackRange(paragraph: fallback, record: missingDurations) == nil)
        let clipped = TranscriptPlaybackRange(paragraph: second, record: record, duration: 0.6)
        precondition(clipped?.end == 0.6)
        state.text = "全文已改写"; state.saveEdits()
        precondition(!state.canPlayTranscriptParagraph(first), "全文变化不使用过期分段")
        print("PASS: 真播放器静音验证点击段落定位/句尾暂停/续录偏移/快速切句/连续回放/拖动退出/缺失和失效时间拒绝。")
    }
}
