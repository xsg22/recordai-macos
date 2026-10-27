import Foundation
import AVFoundation
import Combine

/// 仅供独立UI验收：把合成文件推给真实Paraformer；不调用录音器、不播放扬声器。
@MainActor final class TranscriptReplayDriver: ObservableObject {
    private var session: LiveTranscriptionSession?
    private var task: Task<Void, Never>?
    private weak var state: AppState?
    func start(state: AppState, audio: URL) {
        stop(); self.state = state
        do {
            guard let model = ASRResources.paraformer, let exe = ASRResources.executable("paraformer-live") else { return }
            let file = try AVAudioFile(forReading: audio)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let offset = state.current?.duration ?? 0
            let session = LiveTranscriptionSession();self.session = session
            var committed: [String] = []
            session.onEvent = { [weak state] event in
                DispatchQueue.main.async {
                    guard let state else { return }
                    state.liveStatus = "合成文件推流验收 · 无麦克风采集"
                    let line = "\(event.type): \(event.text)\n"
                    let log = FileManager.default.temporaryDirectory.appendingPathComponent("recordai-ui-replay-events.log")
                    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
                    if let handle = try? FileHandle(forWritingTo: log) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
                    if event.type == "error" { state.error = event.text }
                    if event.type == "partial" { state.livePartial = event.text }
                    if event.type == "commit" {
                        committed.append(event.text); state.livePartial = ""
                        if let index = state.history.firstIndex(where: { $0.id == state.selection }) {
                            state.history[index].liveUtterances.append(LiveUtterance(text: event.text, start: event.start + offset, end: event.end + offset))
                        }
                    }
                    state.liveText = (committed + (event.type == "partial" ? [event.text] : [])).joined(separator: "\n")
                }
            }
            try session.start(model: model, executable: exe, language: "zh")
            state.recording = true;state.paused = false
            state.status = "独立界面验收：输入合成音频流，不采集麦克风"
            task = Task {
                for start in stride(from: 0, to: samples.count, by: 1600) {
                    if Task.isCancelled { return }
                    session.append(Array(samples[start..<min(start + 1600, samples.count)]))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await session.finish()
                state.liveStatus = "合成音频输入完成 · 无麦克风采集"
            }
        } catch { state.error = error.localizedDescription }
    }
    func stop() {
        task?.cancel();task = nil;session?.cancel();session = nil
        state?.recording = false;state?.paused = false;state?.livePartial = ""
    }
}
