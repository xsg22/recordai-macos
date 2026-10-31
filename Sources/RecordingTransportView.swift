import SwiftUI

struct RecordingTransportView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = state.recordingIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(AppTypography.secondary).foregroundStyle(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { monitor; controls }
                VStack(alignment: .leading, spacing: 12) {
                    monitor
                    HStack { Text(state.recordingMode.title).font(AppTypography.secondary).foregroundStyle(.secondary); Spacer(); controls }
                }
            }
        }.padding(14).background(Color.red.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private var monitor: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(clock(state.elapsed)).font(.system(size: 21, weight: .medium)).monospacedDigit()
                Text(state.paused ? "已暂停" : "正在录音").font(AppTypography.secondary).foregroundStyle(.secondary)
                Text(state.recordingMode.title).font(AppTypography.secondary).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 160, alignment: .leading)
            }.fixedSize()
            if state.compactRecordingUI {
                Label("后台录音中", systemImage: "record.circle").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                LiveWaveformView(samples: state.liveLevels, tint: state.paused ? .secondary : Color(red: 0.72, green: 0.29, blue: 0.28))
                    .frame(minWidth: 100, idealWidth: 280, maxWidth: .infinity).frame(height: 42)
            }
        }
    }
    private var controls: some View {
        HStack(spacing: 10) {
            Button(state.paused ? (state.canRetryMicrophone ? "重试并继续" : "继续") : "暂停") { state.pauseRecording() }
                .disabled(state.preparing || state.quitting || (state.recordingIssue != nil && !state.canRetryMicrophone))
            Button { state.toggleRecording() } label: { Label("停止并保存", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.69, green: 0.25, blue: 0.25))
                .disabled(state.preparing || state.quitting)
        }.fixedSize()
    }
    private func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct NativePlaybackBar: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record = state.current, record.audioFiles.count > 1 {
                Picker("播放片段", selection: Binding(get: { state.playbackSegment }, set: { state.selectPlaybackSegment($0) })) {
                    ForEach(record.audioFiles.indices, id: \.self) { index in Text("第 \(index + 1) 段录音").tag(index) }
                }.frame(maxWidth: 260).disabled(state.recording || state.preparing)
            }
            HStack(spacing: 12) {
                Button { state.togglePlayback() } label: { Image(systemName: state.playing ? "pause.fill" : "play.fill").frame(width: 24, height: 28) }
                    .help(state.playing ? "暂停回放" : "播放录音").accessibilityLabel(state.playing ? "暂停回放" : "播放录音")
                    .disabled(state.recording || state.preparing)
                if let audio = state.audio { PlaybackWaveformView(state: state, audio: audio).id(audio) }
                Text(clock(state.playbackTime) + " / " + clock(state.playbackDuration)).font(AppTypography.secondary)
                    .monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
        }.padding(12).background(Color(red: 0.08, green: 0.35, blue: 0.95).opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
