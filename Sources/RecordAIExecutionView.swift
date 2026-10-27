import SwiftUI

struct RecordAIExecutionView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var stages: [(String, String, String, Color)] {
        let capture = state.recording ? "运行中" : "未运行"
        let captureDetail = state.recording ? "MeetingRecorder · \(state.elapsed) 秒" : "等待录音会话"
        let live = state.recording && state.liveEnabled ? "运行中" : state.recording ? "已关闭" : "未运行"
        let liveDetail = state.liveStatus.isEmpty ? "实时 ASR 消费采集回调" : state.liveStatus
        let final = state.continuousProcessing ? "片段处理中" : state.busy ? phaseTitle : state.current?.text.isEmpty == false ? "已保存" : "等待触发"
        let finalDetail = state.continuousProcessing ? "Qwen 处理已关闭片段；录音继续" : state.busy ? state.status : "等待片段或完整音频任务"
        return [
            ("音频采集", capture, captureDetail, state.recording ? .green : .secondary),
            ("实时 ASR", live, liveDetail, state.recording && state.liveEnabled ? .green : .secondary),
            ("片段队列", state.activeRecordingSessionMode == .continuous ? "已启用" : "未启用", state.activeRecordingSessionMode == .continuous ? "已完成 \(state.continuousProcessingCount) · 待处理 \(state.continuousQueuedCount) · 失败 \(state.continuousFailedCount)" : "会议模式保留完整音频", state.activeRecordingSessionMode == .continuous ? .green : .secondary),
            ("最终转录", final, finalDetail, state.continuousProcessing || state.busy ? .blue : .secondary),
            ("发言人 / 对齐", state.continuousProcessing || state.transcriptPhase == .diarizing || state.transcriptPhase == .aligning ? "处理中" : "按需执行", phaseDetail, .secondary),
            ("Agent 发布", state.current == nil ? "等待录音" : "本机快照", "AgentData / CLI / MCP", .green)
        ]
    }

    private var phaseTitle: String {
        switch state.transcriptPhase {
        case .saving: return "保存中"
        case .recognizing: return "识别中"
        case .diarizing: return "分人中"
        case .aligning: return "对齐中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .idle: return "处理中"
        }
    }

    private var phaseDetail: String {
        switch state.transcriptPhase {
        case .diarizing: return "Sortformer"
        case .aligning: return "逐词对齐"
        default: return "正文保存后异步执行"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行追踪").font(.system(size: 24, weight: .semibold))
                    Text("RecordAI 当前真实运行状态；未启用的阶段会明确标记。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("当前会话").font(.headline); Spacer(); Text(state.current?.title ?? "无").foregroundStyle(.secondary).lineLimit(1) }
                    HStack { Text("总状态"); Spacer(); Text(state.status).foregroundStyle(.secondary).lineLimit(1) }
                    HStack { Text("录音时长"); Spacer(); Text(clock(state.elapsed)).monospacedDigit().foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(stage.3).frame(width: 10, height: 10).padding(.top, 5)
                            if index < stages.count - 1 { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36) }
                        }.frame(width: 12)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(stage.0).font(.system(size: 14, weight: .medium)); Spacer(); Text(stage.1).font(.system(size: 13)).foregroundStyle(stage.3) }
                            Text(stage.2).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.bottom, 12)
                    }
                }
            }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Text("片段关闭后依次定稿并区分发言人；录音继续。音频与已保存文字通过 AgentData、CLI 和 MCP 读取。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }.padding(26).frame(width: 620, height: 680).font(AppTypography.body).controlSize(.large)
    }

    private func clock(_ seconds: Int) -> String { String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
}
