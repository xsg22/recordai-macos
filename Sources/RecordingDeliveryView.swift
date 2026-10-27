import SwiftUI
import AppKit

/// 转录占据主画布，旧的附加内容仅作为历史资料只读保留。
struct RecordingCanvasView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.recording && (state.compactRecordingUI || !state.activeRecordingProfile.usesLiveASR) {
                VStack(alignment: .leading, spacing: 16) {
                    Label(state.paused ? "录音已暂停" : "正在安全录音", systemImage: "record.circle").font(AppTypography.heading)
                    Text(state.activeRecordingProfile.usesLiveASR ? "实时识别继续运行，已确认文字持续保存。精简视图减少波形和正文刷新。" : "当前不加载实时识别模型，停止并保存后自动生成转录。")
                        .foregroundStyle(.secondary)
                    if state.mainWindowVisible && state.activeRecordingProfile.usesLiveASR {
                        Button("展开实时正文") { state.expandedRealtime = true }
                    }
                    Text("录音状态也可从菜单栏查看，随时暂停或停止。")
                        .font(AppTypography.secondary).foregroundStyle(.secondary)
                    Spacer()
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TranscriptTimelineView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                if state.recording && state.activeRecordingProfile == .backgroundRealtime {
                    Button("收起实时正文") { state.expandedRealtime = false }
                }
            }
            if let record = state.current, !record.notes.isEmpty || !(record.summary ?? "").isEmpty || !record.enhancedNotes.isEmpty || !record.assistantEntries.isEmpty {
                DisclosureGroup("历史附加内容 · 不包含在默认交付中") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !record.notes.isEmpty { Text("原有笔记").bold(); Text(record.notes) }
                            if let summary = record.summary, !summary.isEmpty { Text("原有摘要").bold(); Text(summary) }
                            if !record.enhancedNotes.isEmpty { Text("原有增强笔记").bold(); Text(record.enhancedNotes) }
                            ForEach(record.assistantEntries) { entry in Text(entry.question).bold(); Text(entry.answer) }
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }.font(AppTypography.secondary)
            }
        }
    }
}
struct RecordingDeliveryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var reviewingSync = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("交付录音与转录").font(.system(size: 24, weight: .semibold))
                    Text(state.title).font(AppTypography.body).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox("文字与音频") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Button(copied ? "已复制正文" : "复制正文") { copy(state.text); copied = true }.disabled(state.text.isEmpty)
                                Button("复制 Markdown") { copy(state.markdown) }.disabled(state.text.isEmpty)
                            }
                            HStack {
                                ForEach(["文本", "Markdown", "JSON", "字幕"], id: \.self) { kind in
                                    Button(kind == "字幕" ? "原始 SRT" : kind == "文本" ? "TXT" : kind) { state.export(kind: kind) }
                                        .disabled(kind == "字幕" && (state.current?.subtitles.isEmpty ?? true))
                                }
                            }
                            Button("导出全部录音片段…") { state.exportAudio() }.disabled(state.locked || state.current?.audioFiles.isEmpty != false)
                            Text("JSON包含时间、分段、发言人及本机音频路径；原始SRT保留识别时的文字，人工校正不会改写它。")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("同步到个人工作区") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("钉钉 · 飞书 · Notion").font(AppTypography.heading)
                            Text("预览转录内容后同步到已连接的个人账号。音频保留在本机。")
                            Button("预览并同步…") { reviewingSync = true }.disabled(!state.canSyncFinalTranscript)
                            if !state.canSyncFinalTranscript { Text("等待转录任务完成后可同步。").font(AppTypography.secondary).foregroundStyle(.secondary) }
                            if !state.syncStatus.isEmpty { Text(state.syncStatus).font(AppTypography.secondary) }
                            if let url = state.remoteURL { Link("打开同步结果", destination: url) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("交给本机 Agent") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("直接读文件，或通过只读 CLI / MCP 接入。无需登录。")
                            Text(state.agentDataURL.path).font(AppTypography.secondary).textSelection(.enabled)
                            HStack {
                                Button("打开数据目录") { state.revealAgentData() }
                                Button("复制接入说明") { copy(state.agentInstructions) }
                            }
                            Text("默认读取定稿；实时草稿须显式请求。外部工具可以自行总结、问答或处理音频。")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                            if let issue = state.agentPublicationError { Text(issue).foregroundStyle(.orange) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.padding(26).frame(width: 720, height: 740).font(AppTypography.body).controlSize(.large)
            .sheet(isPresented: $reviewingSync) { SyncReviewView(state: state, close: { reviewingSync = false }) }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
