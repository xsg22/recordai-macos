import AppKit
import AVFoundation
import Foundation

/// A real silent capture and real (muted) player exercise selection changes
/// without requesting permissions or reading any personal recordings.
@main struct RecordingBrowsingSmoke {
    static func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("recordai-browsing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let library = try MeetingLibrary(root: root.appendingPathComponent("Library"))
        let source = root.appendingPathComponent("history.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        var active = MeetingRecord(title: "正在录制的 A", status: .recording)
        active.previewText = "A 的之前一句"
        _ = try library.save(active)
        var historic = MeetingRecord(title: "历史录音 B", text: "B 的原文", status: .recorded)
        _ = try library.importAudio(source, into: &historic, recordingDuration: 1)
        historic.status = .completed; historic.pendingAudioFiles = []; historic.previewText = "B 的历史预览"
        let paragraph = TranscriptParagraph(text: historic.text, start: 0.1, end: 0.6, audioFile: historic.audioFiles[0], localStart: 0.1)
        historic.transcriptParagraphs = [paragraph]
        _ = try library.save(historic)
        let historicBytes = try Data(contentsOf: library.directory(for: historic.id).appendingPathComponent("meeting.json"))
        let originalAudioBytes = try Data(contentsOf: library.audioURLs(for: historic)[0])
        let capture = MeetingRecorder()
        try await capture.start(sources: .muted, directory: root.appendingPathComponent("Captures"))
        let namespace = "browsing-\(UUID().uuidString)"
        let state = AppState(storageURL: library.root, connectionNamespace: namespace,
                             speechModelStore: ASRModelStore(root: root.appendingPathComponent("NoModels")), recorder: capture)
        state.error = nil; state.playbackVolume = 0
        state.select(active.id); state.bindRecordingContext(to: active.id)
        state.recording = true; state.liveEnabled = false
        state.handleLiveEvent(.init(type: "commit", text: "A 的确认句", start: 0, end: 1), meetingID: active.id)
        state.handleLiveEvent(.init(type: "partial", text: "A 的草稿", start: 1, end: 2), meetingID: active.id)
        let recordingPreview = state.miniTranscriptPreview
        check(state.isViewingRecording && !state.showsInlineRecorder, "录音详情不重复叠加 mini")
        check(!state.canPlayCurrentRecording, "不能播放正在写入的音频")
        state.select(historic.id)
        check(state.canBrowseRecordings && state.showsInlineRecorder && !state.isViewingRecording)
        check(state.activeRecordingID == active.id && state.recordingRecord?.id == active.id)
        check(state.text == historic.text && state.title == historic.title)
        check(state.miniTranscriptPreview == recordingPreview, "浏览 B 不得覆盖 A 的 mini 字幕")
        check(state.displayedLiveText == historic.previewText && state.displayedLivePartial.isEmpty)
        state.mainWindowVisible = false; state.setInlineRecorderVisible(true)
        state.handleLiveEvent(.init(type: "partial", text: "A 的新草稿", start: 1, end: 3), meetingID: active.id)
        check(state.livePartial == "A 的新草稿", "历史页 inline mini 也须即时更新草稿")
        state.handleLiveEvent(.init(type: "commit", text: "A 的新确认句", start: 1, end: 3), meetingID: active.id)
        check(state.miniTranscriptPreview.confirmed == "A 的新确认句")
        check(state.text == historic.text && state.title == historic.title && state.displayedLiveText == historic.previewText)
        state.handleLiveEvent(.init(type: "commit", text: "错误归属不应写入", start: 3, end: 4), meetingID: historic.id)
        check(try library.load(historic.id).previewText == historic.previewText)
        check(state.canPlayTranscriptParagraph(paragraph))
        state.playTranscriptParagraph(paragraph)
        try await Task.sleep(nanoseconds: 60_000_000)
        check(state.playing && state.recording && capture.state == .recording, "历史单句回放不能影响采集")
        let profile = state.activeRecordingProfile, mode = state.recordingMode
        state.search = "不匹配"; state.groupFilter = "ungrouped"
        let revision = state.recordingNavigationRevision
        state.returnToRecording()
        check(state.selection == active.id && state.isViewingRecording && !state.showsInlineRecorder)
        check(state.recordingNavigationRevision == revision + 1 && state.search.isEmpty && state.groupFilter.isEmpty)
        check(!state.playing && capture.state == .recording && state.recording)
        check(state.activeRecordingProfile == profile && state.recordingMode == mode)
        state.select(historic.id)
        state.togglePlayback()
        check(state.playing, "历史完整音频也可以回放")
        state.stopPlayback()
        // Stop while still looking at B. Only A receives the captured audio, and
        // automatic transcription must not consume B's audio or change selection.
        state.toggleRecording()
        for _ in 0..<300 where state.recording || state.preparing { try await Task.sleep(nanoseconds: 20_000_000) }
        check(!state.recording && !state.preparing)
        check(state.selection == historic.id && state.text == historic.text && state.title == historic.title)
        check(state.liveText == historic.previewText && state.livePartial.isEmpty)
        active = try library.load(active.id)
        check(active.audioFiles.count == 1 && active.pendingAudioFiles.count == 1)
        check(active.liveUtterances.map(\.text) == ["A 的确认句", "A 的新确认句"])
        check(try Data(contentsOf: library.directory(for: historic.id).appendingPathComponent("meeting.json")) == historicBytes,
                     "浏览/停止 A 不能写坏 B 的元数据")
        check(try Data(contentsOf: library.audioURLs(for: historic)[0]) == originalAudioBytes)
        check(state.activeRecordingID == nil && !state.showsInlineRecorder)
        print("PASS: 录音/浏览记录隔离、mini 仅历史页显示、返回录音、过滤恢复、历史单句与连续回放、实时正文不串写、停止保存归属与历史文件逐字节保全；使用真实静音采集和静音播放器，无硬件录音。")
    }
}
