import SwiftUI
import AppKit

/// Recording and final-transcript reading surface.
struct RecordingCanvasView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.recording && (state.compactRecordingUI || !state.activeRecordingProfile.usesLiveASR) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(state.paused ? "录音已暂停" : "后台录音中").font(AppTypography.heading).padding(.bottom, 6)
                    Text(state.activeRecordingProfile.usesLiveASR ? "实时识别继续运行。可展开正文查看最新文字。" : "当前不加载实时识别模型，停止并保存后自动生成转录。")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    if state.mainWindowVisible && state.activeRecordingProfile.usesLiveASR {
                        Button("展开实时正文") { state.expandedRealtime = true }
                    }
                }.padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 20).frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                    .background(RecordAITheme.quiet, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 22).help("录音状态也可从菜单栏查看，随时暂停或停止。")
                Spacer(minLength: 0)
            } else {
                TranscriptTimelineView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
                if state.recording && state.activeRecordingProfile == .backgroundRealtime {
                    Button("收起实时正文") { state.expandedRealtime = false }
                }
            }

        }
    }
}
struct RecordingDeliveryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var reviewingSync = false
    @State private var copied = false
    @State private var agentPromptCopied = false
    @State private var showingAgentScope = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecordAIPageHeader(title: "导出与交付", subtitle: state.title + (state.text.isEmpty ? "" : " · 转录已保存")) {
                Button("完成") { dismiss() }
                    .keyboardShortcut(showingAgentScope ? nil : .cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RecordAICard {
                        VStack(alignment: .leading, spacing: 16) {
                        Text("文字与音频").font(AppTypography.heading)
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Button(copied ? "已复制正文" : "复制正文") { copy(state.text); copied = true }.buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.text.isEmpty)
                                Button("复制 Markdown") { copy(state.markdown) }.disabled(state.text.isEmpty)
                            }
                            HStack {
                                ForEach(["文本", "Markdown", "JSON", "字幕"], id: \.self) { kind in
                                    Button(kind == "字幕" ? "原始 SRT" : kind == "文本" ? "TXT" : kind) { state.export(kind: kind) }
                                        .disabled(kind == "字幕" && (state.current?.subtitles.isEmpty ?? true))
                                }
                                Button("全部音频") { state.exportAudio() }.fixedSize().disabled(state.locked || state.current?.audioFiles.isEmpty != false)
                            }
                            Text("JSON包含时间、分段、发言人及本机音频路径；原始SRT保留识别时的文字，人工校正不会改写它。")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
                    }
                    RecordAICard {
                        VStack(alignment: .leading, spacing: 16) {
                        Text("同步到个人工作区").font(AppTypography.heading)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("钉钉 · 飞书 · Notion。预览内容后保存到已连接账号，音频保留在本机。")
                            Button("预览并同步…") { reviewingSync = true }.buttonStyle(RecordAIPrimaryButtonStyle()).disabled(!state.canSyncFinalTranscript)
                            if !state.canSyncFinalTranscript { Text("等待转录任务完成后可同步。").font(AppTypography.secondary).foregroundStyle(.secondary) }
                            if !state.syncStatus.isEmpty { Text(state.syncStatus).font(AppTypography.secondary) }
                            if let url = state.remoteURL { Link("打开同步结果", destination: url) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
                    }
                    RecordAICard(quiet: true) {
                        VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("交给本机 Agent").font(AppTypography.heading)
                            Spacer()
                            Button { showingAgentScope = true } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.plain).foregroundStyle(RecordAITheme.muted)
                                .accessibilityLabel("数据目录与读取范围")
                                .popover(isPresented: $showingAgentScope) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack {
                                            Text("数据目录与读取范围").font(AppTypography.heading)
                                            Spacer()
                                            Button("关闭") { showingAgentScope = false }
                                                .keyboardShortcut(.cancelAction)
                                        }
                                        Text(state.agentDataURL.path).font(AppTypography.secondary).textSelection(.enabled)
                                        Text("只读接入，无需登录。默认读取定稿；实时草稿须显式请求。外部工具可以自行总结、问答或处理音频。")
                                            .font(AppTypography.secondary).foregroundStyle(.secondary)
                                    }.padding(20).frame(width: 420)
                                }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("直接读文件，或通过 CLI / MCP 读取定稿与录音信息。")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                            HStack {
                                Button(agentPromptCopied ? "已复制接入提示词" : "复制接入提示词") { agentPromptCopied = state.copyAgentPrompt() }
                                Button("打开数据目录") { state.revealAgentData() }
                            }
                            if let issue = state.agentPublicationError { Text(issue).foregroundStyle(.orange) }
                            if let issue = state.agentSetupIssue { Text(issue).foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity, minHeight: 115, alignment: .topLeading)
                    }
                }
            }
        }.padding(28).frame(width: 720, height: 740).font(AppTypography.body)
            .buttonStyle(RecordAISecondaryButtonStyle()).tint(RecordAITheme.accent)
            .sheet(isPresented: $reviewingSync) { SyncReviewView(state: state, close: { reviewingSync = false }) }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
