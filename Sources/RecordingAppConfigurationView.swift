import SwiftUI
import AppKit

struct RecordingAppConfigurationView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @State private var section = "recording"
    @State private var showingSpeechModels = false
    init(state: AppState, initialSection: String = "recording") {
        self.state = state; _section = State(initialValue: initialSection)
    }
    private let sections = [("recording", "录音与转录", "waveform"), ("models", "本地模型", "cpu"), ("accounts", "同步账号", "person.crop.circle"), ("data", "Agent 与数据", "externaldrive")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("设置")).font(.system(size: 20, weight: .semibold)).padding(.horizontal, 12).padding(.bottom, 18)
                ForEach(sections, id: \.0) { item in
                    Button { section = item.0 } label: {
                        Label(L10n.text(item.1), systemImage: item.2).font(AppTypography.secondary.weight(section == item.0 ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(section == item.0 ? RecordAITheme.accent : .primary)
                            .background(section == item.0 ? RecordAITheme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(section == item.0 ? .isSelected : [])
                }
                Spacer()
                Label(L10n.text("本机存储"), systemImage: "lock.shield").font(AppTypography.secondary).foregroundStyle(.secondary).padding(12)
            }.padding(.horizontal, 12).padding(.vertical, 28).frame(width: 190)
                .background(RecordAITheme.sidebar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case "models": models
                    case "accounts": accounts
                    case "data": data
                    default: recording
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(RecordAITheme.surface)
        }.frame(width: 920, height: 632).font(AppTypography.body)
            .buttonStyle(RecordAISecondaryButtonStyle()).tint(RecordAITheme.accent)
            .sheet(isPresented: $showingSpeechModels) {
                VStack(alignment: .leading, spacing: 20) {
                    ASRModelSetupView(store: state.speechModels, close: { showingSpeechModels = false })
                }.padding(28).frame(width: 720).buttonStyle(RecordAISecondaryButtonStyle())
            }
    }

    private var recording: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("录音与转录"), subtitle: L10n.text("设置下一次录音使用的音源和处理方式。")) { EmptyView() }
            RecordAICard(spacing: 0) {
                RecordAISettingRow(title: L10n.text("界面语言")) {
                    Picker(L10n.text("界面语言"), selection: $appLanguage.selection) {
                        ForEach(InterfaceLanguage.allCases) { Text($0.name).tag($0) }
                    }.id(appLanguage.effective).labelsHidden().accessibilityLabel(L10n.text("界面语言"))
                }
                Text(L10n.text("界面语言与转录语言分别设置，不会翻译已有录音内容。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                RecordAISettingRow(title: L10n.text("默认音源")) {
                    RecordAIChoicePicker(title: "默认音源", items: MeetingRecordingMode.allCases.map { ($0.title, $0) }, selection: $state.recordingMode)
                }
                Divider()
                RecordAISettingRow(title: L10n.text("会话类型")) {
                    RecordAIChoicePicker(title: "录音会话", items: RecordingSessionMode.allCases.map { ($0.title, $0) }, selection: $state.recordingSessionMode)
                }
                Divider()
                RecordAISettingRow(title: L10n.text("默认转录语言")) {
                    RecordAIChoicePicker(title: L10n.text("默认转录语言"), items: TranscriptionLanguage.allCases.map { ($0.title, $0.rawValue) }, selection: $state.language)
                }
                Divider()
                RecordAISettingRow(title: L10n.text("录音模式")) {
                    RecordAIChoicePicker(title: "录音模式", items: RecordingProfile.allCases.map { ($0.title, $0) }, selection: $state.recordingProfile)
                }
            }.disabled(state.locked)
            RecordAICard(quiet: true) {
                Text(L10n.text(state.recordingProfile.title)).font(AppTypography.heading)
                Text(L10n.text(state.recordingProfile.detail)).font(AppTypography.secondary).foregroundStyle(.secondary).lineSpacing(7)
            }
            RecordAIInfo(text: L10n.text("录音过程中设置会锁定，修改只影响下一次录音。隐藏窗口或切换 mini 不会停止采集。"))
            RecordAIInfo(text: L10n.text("普通话和英语实时字幕使用中英双语模型，最终转录遵循所选语言。"))
            RecordAIInfo(text: L10n.text("粤语实时字幕分段更新，可能有数秒延迟；录音结束后生成完整转录。"))
        }
    }

    private var models: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("本地模型"), subtitle: L10n.text("管理实时转写和最终转录所需的语音模型。")) { EmptyView() }
            RecordAICard(spacing: 20) {
                Text(L10n.text("语音识别")).font(AppTypography.heading)
                HStack {
                    Text(L10n.text("实时转写与最终转录")).font(AppTypography.body)
                    Spacer()
                    Label(L10n.text(state.speechModels.ready ? "已就绪" : state.speechModels.busy ? "下载中" : "尚未下载"), systemImage: state.speechModels.ready ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(AppTypography.secondary).foregroundStyle(state.speechModels.ready ? Color.green : .secondary)
                }
                Button(L10n.text("查看语音模型")) { showingSpeechModels = true }
            }
        }
    }

    private var accounts: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("同步账号"), subtitle: L10n.text("连接个人账号，转录完成后预览并同步。")) { EmptyView() }
            RecordAISegmentedPicker(items: PersonalDestination.allCases.map { (L10n.text($0.rawValue), $0) }, selection: $state.syncDestination)
            AccountConnectionPanel(state: state)
            RecordAIInfo(text: L10n.text("只在你点击同步后发送选定文字。原始音频保留在本机。"))
        }
    }

    private var data: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("Agent 与本机资料"), subtitle: L10n.text("管理录音存储和其他本机工具的读取入口。")) { EmptyView() }
            RecordAICard(quiet: true) { AgentConnectionView(state: state) }
            RecordAICard {
                Label(L10n.text("本机 Agent"), systemImage: "externaldrive").font(AppTypography.heading)
                Text(state.agentDataURL.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(RecordAITheme.border, lineWidth: 1))
                ViewThatFits {
                    HStack { agentActions }
                    VStack(alignment: .leading, spacing: 10) { agentActions }
                }
                Text(L10n.text("默认读取定稿。外部工具可通过文件、CLI 或 MCP 消费；实时草稿须显式请求。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                if let issue = state.agentPublicationError { RecordAIInfo(text: L10n.text(issue), warning: true) }
            }
            RecordAICard {
                Text(L10n.text("原始资料")).font(AppTypography.heading)
                Text(state.dataRootURL.path).font(AppTypography.secondary).textSelection(.enabled)
                HStack {
                    Button(L10n.text("打开资料目录")) { state.revealDataRoot() }
                    if state.current != nil { Button(L10n.text("当前录音目录")) { state.revealStorage() } }
                }
                Text(L10n.text("原始音频和历史内容保留在本机。卸载应用不会自动删除资料。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var agentActions: some View {
        Button(L10n.text("打开数据目录")) { state.revealAgentData() }
        Button(L10n.text("重新发布快照")) { state.republishAgentData() }.disabled(state.locked)
    }
}
