import SwiftUI

struct RecordingTransportView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(state.paused || state.recordingIsMuted ? Color.secondary : .red).frame(width: 7, height: 7)
                Text(L10n.text(state.paused ? "录音已暂停" : state.recordingIsMuted ? "静音录制" : "正在录音"))
                Text(String(format: "%02d:%02d:%02d", state.elapsed / 3600, state.elapsed / 60 % 60, state.elapsed % 60)).fontWeight(.semibold).monospacedDigit()
            }.font(AppTypography.body).foregroundStyle(state.paused || state.recordingIsMuted ? Color.secondary : .red)
            LiveWaveformView(samples: state.liveLevels, tint: TalkTuckTheme.accent)
                .frame(height: 78).padding(.horizontal, 14).padding(.vertical, 27)
                .background(LinearGradient(colors: [TalkTuckTheme.waveStart, TalkTuckTheme.waveEnd], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 13))
            HStack { Text("00:00"); Spacer(); Text(clock(state.elapsed)) }
                .font(AppTypography.secondary).monospacedDigit().foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sourceControls; Spacer(minLength: 12); transportControls }
                VStack(alignment: .leading, spacing: 12) {
                    sourceControls
                    HStack { Spacer(); transportControls }
                }
            }.padding(.vertical, 6)
        }
    }
    private var sourceControls: some View {
        HStack(spacing: 8) {
            RecordingSourceToggle(state: state, kind: .microphone)
            RecordingSourceToggle(state: state, kind: .system)
        }.fixedSize()
    }
    private var transportControls: some View {
        HStack(spacing: 8) {
                Button { state.pauseRecording() } label: {
                    Label(L10n.text(state.paused ? "继续录音" : "暂停录音"), systemImage: state.paused ? "play.fill" : "pause.fill")
                }.buttonStyle(TalkTuckSecondaryButtonStyle()).accessibilityLabel(L10n.text(state.paused ? (state.canRetryMicrophone ? "重试并继续" : "继续录音") : "暂停录音"))
                    .help(L10n.text(state.paused ? "继续录音" : "暂停录音"))
                    .disabled(state.preparing || state.quitting || (state.recordingIssue != nil && !state.canRetryMicrophone))
                Button { state.toggleRecording() } label: { Label(L10n.text("停止并保存"), systemImage: "stop.fill") }
                    .buttonStyle(TalkTuckPrimaryButtonStyle()).disabled(state.preparing || state.quitting)
        }.fixedSize()
    }
    private func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct NativePlaybackBar: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record = state.current, record.audioFiles.count > 1 {
                Picker(L10n.text("播放片段"), selection: Binding(get: { state.playbackSegment }, set: { state.selectPlaybackSegment($0) })) {
                    ForEach(record.audioFiles.indices, id: \.self) { index in Text(L10n.text("第 \(index + 1) 段录音")).tag(index) }
                }.frame(maxWidth: 260).disabled(!state.canPlayCurrentRecording)
            }
            if let audio = state.audio {
                PlaybackWaveformView(state: state, audio: audio).id(audio).padding(.horizontal, 14).padding(.vertical, 27)
                    .background(LinearGradient(colors: [TalkTuckTheme.waveStart, TalkTuckTheme.waveEnd], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 13))
            }
            HStack {
                Text("00:00"); Spacer(); Text(clock(state.playbackDuration))
            }.font(AppTypography.secondary).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 30) {
                Spacer()
                Button { state.seek(state.playbackTime - 15) } label: { Image(systemName: "gobackward.15") }
                    .buttonStyle(.plain).help(L10n.text("后退 15 秒")).accessibilityLabel(L10n.text("后退 15 秒"))
                Button { state.togglePlayback() } label: { Image(systemName: state.playing ? "pause.fill" : "play.fill").font(.system(size: 20)).foregroundStyle(.white).frame(width: 52, height: 52).background(TalkTuckTheme.primaryFill, in: Circle()) }
                    .buttonStyle(.plain).help(L10n.text(state.playing ? "暂停回放" : "播放录音")).accessibilityLabel(L10n.text(state.playing ? "暂停回放" : "播放录音"))
                Button { state.seek(state.playbackTime + 15) } label: { Image(systemName: "goforward.15") }
                    .buttonStyle(.plain).help(L10n.text("前进 15 秒")).accessibilityLabel(L10n.text("前进 15 秒"))
                Spacer()
            }.disabled(!state.canPlayCurrentRecording).padding(.top, 15).padding(.bottom, 7)
        }
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
