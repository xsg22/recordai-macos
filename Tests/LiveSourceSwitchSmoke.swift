import AppKit
import AVFoundation
import Foundation

@main struct LiveSourceSwitchSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordai-source-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let both = RecordingSources(mode: .meeting)
        precondition(both.toggling(.microphone).toggling(.system).isMuted, "两个音源必须允许同时关闭")
        var timeline = RecordingSourceTimeline(started: 100, sources: both)
        timeline.setSources(.muted, at: 101)
        timeline.setSources(RecordingSources(mode: .microphone), at: 102)
        precondition(timeline.slices(kind: .microphone, at: 100.5, frames: 48_000, sampleRate: 16_000) == [0..<8000, 24_000..<48_000])
        precondition(timeline.slices(kind: .system, at: 102, frames: 1600, sampleRate: 16_000).isEmpty)
        let directory = root.appendingPathComponent("gated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var live: [Float] = []
        let sink = MeetingAudioSink(directory: directory, started: 100, mode: .meeting, onAudio: { live += $0 }) { fatalError("\($0)") }
        sink.setSources(.muted, at: 101)
        sink.setSources(RecordingSources(mode: .microphone), at: 102)
        sink.setSources(both, at: 103)
        sink.setSources(.muted, at: 104)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<80_000 { buffer.floatChannelData![0][index] = 0.3 }
        // Delayed callbacks span multiple switches: only enabled subranges may
        // reach disk or the streaming recognizer. Mute time must not disappear.
        sink.appendMicrophone(buffer, at: 100)
        sink.appendSystemAudio(buffer, at: 100)
        sink.advance(to: 105)
        let tracks = sink.finish(duration: 5)
        precondition(tracks.count == 2)
        for track in tracks {
            let file = try AVAudioFile(forReading: track.url)
            let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: samples)
            precondition(file.length == 64_000 && track.offset == 0)
            let data = samples.floatChannelData![0]
            precondition(abs(data[8000] - 0.3) < 0.0001)
            precondition(abs(data[24_000]) < 0.0001, "静音部分不能漏入旧音频")
            precondition(abs(data[40_000] - (track.kind == .microphone ? 0.3 : 0)) < 0.0001)
            precondition(abs(data[56_000] - 0.3) < 0.0001)
        }
        precondition(live.count == 80_000 && live.suffix(12_000).allSatisfy { abs($0) < 0.0001 }, "静音尾部必须进入实时与持续切片时间轴")
        let events = try JSONDecoder().decode([RecordingSourceTimeline.Event].self, from: Data(contentsOf: directory.appendingPathComponent("sources.json")))
        precondition(events.count == 5 && events.last!.sources.isMuted)
        let destination = root.appendingPathComponent("gated.m4a")
        try await MeetingAudioMixer.mix(tracks: tracks, destination: destination, duration: 5)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        precondition(abs(duration - 5) < 0.03)
        // Exercise the actual recorder's timer, pause/resume and silent export
        // without requesting TCC or collecting any microphone/system audio.
        let recorder = MeetingRecorder()
        try await recorder.start(sources: .muted, directory: root)
        precondition(recorder.state == .recording && recorder.activeSources.isMuted)
        if (try? MeetingRecorder.requireMicrophone()) == nil {
            do { try await recorder.toggleSource(.microphone); preconditionFailure("无设备不能开启麦克风") }
            catch { precondition(recorder.state == .recording && recorder.activeSources.isMuted) }
        }
        try await Task.sleep(nanoseconds: 240_000_000)
        recorder.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(recorder.resume())
        try await Task.sleep(nanoseconds: 240_000_000)
        let recording = try await recorder.stop()
        precondition(recording.seconds >= 0.45 && recording.seconds < 0.65, "静音计时继续，暂停时间排除")
        let silent = try AVAudioFile(forReading: recording.audioURL)
        let silentBuffer = AVAudioPCMBuffer(pcmFormat: silent.processingFormat, frameCapacity: AVAudioFrameCount(silent.length))!
        try silent.read(into: silentBuffer)
        precondition(UnsafeBufferPointer(start: silentBuffer.floatChannelData![0], count: Int(silentBuffer.frameLength)).allSatisfy { abs($0) < 0.001 })
        precondition(recorder.state == .idle)
        // Projection and foreground mini flushing use the same saved live text.
        let preview = MiniTranscriptPreview(text: "之前一句\n最近确认句\n当前草稿", partial: "当前草稿")
        precondition(preview.confirmed == "最近确认句" && preview.partial == "当前草稿")
        let namespace = "mini-stream-\(UUID().uuidString)"
        let library = try MeetingLibrary(root: root.appendingPathComponent("Library"))
        let record = MeetingRecord(title: "隔离字幕测试")
        _ = try library.save(record)
        let state = AppState(storageURL: library.root, connectionNamespace: namespace)
        state.select(record.id); state.recording = true; state.mainWindowVisible = false
        state.setMiniWindowVisible(true)
        state.handleLiveEvent(.init(type: "partial", text: "第一段草稿", start: 0, end: 1), meetingID: record.id)
        state.handleLiveEvent(.init(type: "partial", text: "立即更新的草稿", start: 0, end: 2), meetingID: record.id)
        precondition(state.livePartial == "立即更新的草稿", "可见 mini 不应被隐藏主窗口的两秒节流阻塞")
        state.handleLiveEvent(.init(type: "commit", text: "确认句", start: 0, end: 2), meetingID: record.id)
        state.handleLiveEvent(.init(type: "partial", text: "新一句", start: 2, end: 3), meetingID: record.id)
        precondition(state.miniTranscriptPreview == MiniTranscriptPreview(text: "确认句\n新一句", partial: "新一句"))
        state.recording = false
        print("PASS: 双音源全关、延迟帧裁切、静音不压缩时间、两轨恢复、切换清单、静音实际导出、无设备失败保全、暂停恢复与 mini 实时草稿同步；未采集真实硬件音频。")
    }
}
