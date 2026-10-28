import SwiftUI

struct LiveWaveformView: View {
    let samples: [Float]
    var tint: Color = .red
    var body: some View {
        Canvas { context, size in
            let count = max(1, samples.count)
            let step = size.width / CGFloat(count)
            for (index, sample) in samples.enumerated() {
                let height: CGFloat = max(2, size.height * CGFloat(sqrt(max(0, min(1, sample)))))
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1, min(4, step - 1)), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint))
            }
        }.accessibilityLabel("实时录音声波").accessibilityValue(samples.last.map { $0 > 0.005 ? "检测到声音" : "静音" } ?? "等待音频")
    }
}

struct PlaybackWaveformView: View {
    @ObservedObject var state: AppState
    let audio: URL
    @State private var waveform: AudioWaveform?
    @State private var issue: String?
    @State private var loading = true
    @FocusState private var seeking: Bool
    private let accent = Color(red: 0.14, green: 0.39, blue: 0.34)
    private var duration: Double { max(0.001, state.playbackDuration > 0 ? state.playbackDuration : waveform?.duration ?? 0.001) }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        let count = max(1, Int(size.width / 5))
                        let step = size.width / CGFloat(count)
                        for index in 0..<count {
                            let peaks = waveform?.peaks ?? []
                            let start = index * peaks.count / count, end = (index + 1) * peaks.count / count
                            let value = start < end ? peaks[start..<end].max() ?? 0 : peaks.isEmpty ? 0 : peaks[min(start, peaks.count - 1)]
                            let height: CGFloat = max(2, size.height * CGFloat(sqrt(value)))
                            let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                              width: max(1, step - 2), height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                with: .color(Double(index) / Double(count) < state.playbackTime / duration ? accent : accent.opacity(0.25)))
                        }
                    }.accessibilityHidden(true)
                    Rectangle().fill(accent).frame(width: 2)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * state.playbackTime / duration)))
                        .accessibilityHidden(true)
                    Slider(value: Binding(get: { min(duration, max(0, state.playbackTime)) }, set: { state.seek($0) }), in: 0...duration)
                        .labelsHidden().focused($seeking).opacity(0.015).accessibilityLabel("音频波形播放进度")
                        .accessibilityValue("\(Int(state.playbackTime)) 秒，共 \(Int(duration)) 秒")
                        .disabled(state.recording || state.preparing)
                }
            }.frame(height: 44).overlay(RoundedRectangle(cornerRadius: 6).stroke(seeking ? accent : .clear, lineWidth: 2))
            if loading { Text("声波正在生成，可直接播放").font(AppTypography.secondary).foregroundStyle(.secondary) }
            if let issue { Text(issue).font(AppTypography.secondary).foregroundStyle(.secondary).lineLimit(2) }
        }
        .task(id: audio, priority: .utility) {
            waveform = nil; issue = nil; loading = true
            do {
                let loaded = try await AudioWaveformStore.shared.load(audio)
                try Task.checkCancellation()
                waveform = loaded
                if state.audio == audio && state.playbackDuration <= 0 { state.playbackDuration = loaded.duration }
            } catch is CancellationError { return }
            catch { issue = "声波暂不可用，仍可回放或拖动定位" }
            loading = false
        }
    }
}
