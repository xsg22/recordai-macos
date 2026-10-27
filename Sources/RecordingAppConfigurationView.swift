import SwiftUI
import AppKit

struct RecordingAppConfigurationView: View {
    @ObservedObject var state: AppState
    var body: some View {
        TabView {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("录音与转录").font(.system(size: 24, weight: .semibold))
                Picker("录音会话", selection: $state.recordingSessionMode) {
                    ForEach(RecordingSessionMode.allCases) { Text($0.title).tag($0) }
                }.disabled(state.locked)
                Text(state.recordingSessionMode.detail).font(AppTypography.secondary).foregroundStyle(.secondary)
                Picker("默认音源", selection: $state.recordingMode) {
                    ForEach(MeetingRecordingMode.allCases) { Text($0.title).tag($0) }
                }.disabled(state.locked)
                Picker("转写语言", selection: $state.language) {
                    Text("中文").tag("zh"); Text("中英自动").tag("auto"); Text("英语").tag("en")
                }.disabled(state.locked)
                Picker("录音模式", selection: $state.recordingProfile) {
                    ForEach(RecordingProfile.allCases) { Text($0.title).tag($0) }
                }.disabled(state.locked)
                Text(state.recordingProfile.detail).font(AppTypography.secondary).foregroundStyle(.secondary)
                Text("默认实时转录，不因窗口隐藏而关闭识别。模式选择只对下一次录音生效。")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                Divider()
                Label("实时转录 · Paraformer + Silero VAD", systemImage: "waveform")
                Label("最终转录 · Qwen3-ASR", systemImage: "text.alignleft")
                Label("发言人 · Sortformer + Qwen 逐词对齐", systemImage: "person.2")
                ASRModelSetupView(store: state.speechModels)
                Text("模型下载后在本机处理音频；持续录音逐片段定稿和分人，会议录音停止后处理。")
                    .foregroundStyle(.secondary)
                Text("每段录音最多区分4位声音；续录标签独立，可以在正文中手动合并。")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                Spacer()
            }.padding(28)
            }.tabItem { Label("转录", systemImage: "waveform") }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("同步账号").font(.system(size: 24, weight: .semibold))
                    Text("连接个人账号，转录完成后预览并同步。")
                        .foregroundStyle(.secondary)
                    Picker("平台", selection: $state.syncDestination) {
                        ForEach(PersonalDestination.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    AccountConnectionPanel(state: state)
                }.padding(28)
            }.tabItem { Label("同步账号", systemImage: "person.crop.circle") }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("本机 Agent 与数据").font(.system(size: 24, weight: .semibold))
                    Text("音频和转录保存在这台Mac。外部Agent可通过文件、CLI或MCP只读消费，不需要启动语音模型。")
                    GroupBox("本机 Agent") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(state.agentDataURL.path).font(AppTypography.secondary).textSelection(.enabled)
                            Button("打开只读快照目录") { state.revealAgentData() }
                            Button("复制 CLI / MCP 接入说明") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.agentInstructions, forType: .string)
                            }
                            Button("重新发布全部快照") { state.republishAgentData() }.disabled(state.locked)
                            if let issue = state.agentPublicationError { Text(issue).foregroundStyle(.orange) }
                            Text("快照默认持续更新。同一系统用户可访问；不会自动修改外部Agent配置。")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("原始资料") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(state.dataRootURL.path).font(AppTypography.secondary).textSelection(.enabled)
                            Button("打开本地数据文件夹") { state.revealDataRoot() }
                            if state.current != nil { Button("打开当前录音文件夹") { state.revealStorage() } }
                            Text("原始录音、历史笔记和生成内容仍保留。卸载App不会自动删除数据。")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(28)
            }.tabItem { Label("Agent 与数据", systemImage: "externaldrive") }
        }.frame(width: 760, height: 760).font(AppTypography.body).controlSize(.extraLarge)
    }
}
