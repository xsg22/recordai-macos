import SwiftUI

struct RecordAIExecutionView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var stages: [(String, String, String, Color)] {
        let hasSavedAudio = state.current?.audioFiles.isEmpty == false
        let hasLiveHistory = state.current?.liveUtterances.isEmpty == false || state.current?.legacyLiveText.isEmpty == false
        let capture = state.recording ? "运行中" : hasSavedAudio ? "已结束" : "未运行"
        let captureDetail = state.recording ? "MeetingRecorder · \(state.elapsed) 秒" : hasSavedAudio ? "原始音频已保存" : "等待录音会话"
        let live = state.recording && state.liveEnabled ? "运行中" : state.recording ? "已关闭" : hasLiveHistory ? "已结束" : "未运行"
        let liveDetail = !state.recording && hasLiveHistory ? "草稿保留在实时历史" : state.liveStatus.isEmpty ? "实时 ASR 消费采集回调" : state.liveStatus
        let final = state.continuousProcessing ? "片段处理中" : state.busy ? phaseTitle : state.current?.text.isEmpty == false ? "已保存" : "等待触发"
        let finalDetail = state.continuousProcessing ? "Qwen 处理已关闭片段；录音继续" : state.busy && state.transcriptPhase == .recognizing ? "Qwen 识别音频片段" : state.busy ? state.status : "等待片段或完整音频任务"
        return [
            ("音频采集", capture, captureDetail, state.recording ? .green : .secondary),
            ("实时 ASR", live, liveDetail, state.recording && state.liveEnabled ? .green : .secondary),
            ("片段队列", state.activeRecordingSessionMode == .continuous ? "已启用" : "未启用", state.activeRecordingSessionMode == .continuous ? "已完成 \(state.continuousProcessingCount) · 待处理 \(state.continuousQueuedCount) · 失败 \(state.continuousFailedCount)" : "会议模式保留完整音频", state.activeRecordingSessionMode == .continuous ? .green : .secondary),
            ("最终转录", final, finalDetail, state.continuousProcessing || state.busy ? .blue : .secondary),
            ("发言人 / 对齐", state.continuousProcessing || state.transcriptPhase == .diarizing || state.transcriptPhase == .aligning ? "处理中" : state.busy ? "等待" : "按需执行", phaseDetail, .secondary),
            ("Agent 发布", state.current == nil ? "等待录音" : state.agentPublicationError == nil ? "已就绪" : "待修复", state.agentPublicationError ?? "已保存快照可供本机工具读取", state.current == nil ? .secondary : state.agentPublicationError == nil ? .green : .orange)
        ]
    }

    private var phaseTitle: String {
        switch state.transcriptPhase {
        case .saving: return "保存中"
        case .recognizing: return "处理中"
        case .diarizing: return "分人中"
        case .aligning: return "对齐中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .idle: return "处理中"
        }
    }

    private var sessionStatus: String {
        if state.recording { return state.paused ? "已暂停" : "录音中" }
        if state.preparing || state.busy || state.continuousProcessing || state.recoveryBusy { return "处理中" }
        if state.transcriptPhase == .failed { return "待重试" }
        return state.current?.status == .completed ? "已完成" : "待处理"
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
            RecordAIPageHeader(title: "执行追踪", subtitle: "当前会话的真实处理阶段。") { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            RecordAICard(quiet: true) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(state.current?.title ?? "无录音会话").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text(sessionStatus).font(.system(size: 11)).foregroundStyle(RecordAITheme.muted)
                            .help("录音时长：" + clock(state.elapsed > 0 ? state.elapsed : Int(state.current?.duration ?? 0)))
                    }.frame(minHeight: 46)
                    Divider()
                    HStack { Text("总状态"); Spacer(); Text(state.status).lineLimit(2) }.frame(minHeight: 46)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(stage.1 == "待修复" || stage.1 == "失败" ? Color.orange : RecordAITheme.accent)
                            .frame(width: 10, height: 10).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stage.0).font(.system(size: 14, weight: .semibold))
                            Text(stage.2).font(.system(size: 12)).foregroundStyle(RecordAITheme.muted).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(stage.1).font(.system(size: 11)).foregroundStyle(RecordAITheme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .frame(minHeight: 44, alignment: .top)
                            .background(RecordAITheme.quiet, in: RoundedRectangle(cornerRadius: 6))
                    }.padding(.vertical, 13).frame(minHeight: 71, alignment: .top)
                }
            }.padding(20).background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordAITheme.border, lineWidth: 1))
                .help("片段关闭后依次定稿并区分发言人；录音继续。音频与已保存文字通过 AgentData、CLI 和 MCP 读取。")
            Spacer()
        }.padding(28).frame(width: 720, height: 780).font(AppTypography.body)
            .buttonStyle(RecordAISecondaryButtonStyle()).tint(RecordAITheme.accent)
    }

    private func clock(_ seconds: Int) -> String { String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
}
