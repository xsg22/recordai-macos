import SwiftUI
import AppKit

struct RecordingAppConfigurationView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @State private var section = "recording"
    @State private var showingSpeechModels = false
    @State private var newHotword = ""
    @StateObject private var hotwordModel = HotwordModelStore()
    init(state: AppState, initialSection: String = "recording") {
        self.state = state; _section = State(initialValue: initialSection)
    }
    private let sections = [("recording", "录音与转录", "waveform"), ("models", "本地模型", "cpu"), ("hotwords", "个人热词", "text.book.closed"), ("talktuck", "TalkTuck 账号", "person.crop.circle"), ("accounts", "第三方账号", "link"), ("data", "Agent 与数据", "externaldrive")]
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
                        .accessibilityIdentifier("settings-section-" + item.0)
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
                    case "hotwords": hotwordSettings
                    case "talktuck": talkTuckAccount
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

    private var hotwordSettings: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("个人热词"), subtitle: L10n.text("确认的人名、项目名和术语会用于后续本地最终转录。")) { EmptyView() }
            RecordAICard {
                HStack {
                    Text(L10n.text("本地候选词模型")).font(AppTypography.heading)
                    Spacer()
                    Text(L10n.text(hotwordModel.ready ? "已就绪" : "尚未下载")).font(AppTypography.secondary)
                }
                Text(L10n.text("模型约 0.9 GB，下载后在本机提取候选词；不会上传转录。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                if !hotwordModel.ready {
                    Button(L10n.text("下载本地提取模型")) { hotwordModel.download() }.disabled(hotwordModel.busy)
                }
                if hotwordModel.busy { ProgressView(); Button(L10n.text("取消下载")) { hotwordModel.cancel() } }
                if !hotwordModel.status.isEmpty { Text(L10n.text(hotwordModel.status)).font(AppTypography.secondary).foregroundStyle(.secondary) }
            }.task { hotwordModel.refresh() }
            RecordAICard {
                Text(L10n.format("已确认 · {0}", String(state.hotwords.words.count))).font(AppTypography.heading)
                HStack {
                    TextField(L10n.text("输入专有名词"), text: $newHotword).textFieldStyle(.roundedBorder)
                    Button(L10n.text("添加")) { if state.hotwords.add(newHotword) { newHotword = "" } }
                }
                ForEach(state.hotwords.words, id: \.self) { word in
                    HStack { Text(word); Spacer(); Button(L10n.text("删除")) { state.hotwords.remove(word) } }
                }
                if state.hotwords.words.isEmpty { Text(L10n.text("还没有已确认的热词。")).foregroundStyle(.secondary) }
                Text(L10n.text("优先选择标题或前文中出现的词，不足时补充最近确认的词，每段最多 12 个。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            RecordAICard {
                HStack {
                    Text(L10n.format("待确认 · {0}", String(state.hotwords.candidates.count))).font(AppTypography.heading)
                    Spacer()
                    Button(L10n.text("从当前转录提取")) { state.hotwords.extract(from: state.text) }
                        .disabled(state.hotwords.extracting || state.text.isEmpty || state.locked)
                }
                Text(L10n.text("候选词来自本地模型，可能有误；请对照录音确认拼写。")).font(AppTypography.secondary).foregroundStyle(.secondary)
                ForEach(state.hotwords.candidates) { candidate in
                    VStack(alignment: .leading) {
                        HStack { Text(candidate.word).fontWeight(.semibold); Spacer(); Button(L10n.text("加入")) { state.hotwords.accept(candidate) }; Button(L10n.text("忽略")) { state.hotwords.reject(candidate) } }
                        Text(candidate.context).font(AppTypography.secondary).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if !state.hotwords.status.isEmpty { Text(L10n.text(state.hotwords.status)).font(AppTypography.secondary).foregroundStyle(.secondary) }
            }
            RecordAICard {
                HStack {
                    Text(L10n.text(state.hotwordSync.status)).font(AppTypography.secondary)
                    Spacer()
                    if state.cloudAccount.isSignedIn { Button(L10n.text("立即同步")) { Task { await state.hotwordSync.synchronize() } }.disabled(state.hotwordSync.syncing) }
                    else { Button(L10n.text("登录 TalkTuck")) { section = "talktuck" } }
                }
                Text(L10n.text("登录 TalkTuck 后，仅已确认热词自动同步；候选词和录音不会因热词同步而上传。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private var talkTuckAccount: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("TalkTuck 账号"), subtitle: L10n.text("登录后，按需同步 iPhone 与 Mac 上的文字、分组和原音。")) { EmptyView() }
            TalkTuckAccountPanel(store: state.cloudAccount).disabled(state.locked)
            if state.cloudAccount.isSignedIn, state.cloudAccount.librarySyncAvailable, let engine = state.librarySync {
                RecordAICard { LibrarySyncPanel(engine:engine,choices:state.history.filter { $0.userId == nil && $0.canSelectFinalForSync }.map { LibrarySyncChoice(id:$0.id,title:$0.title,isLocalFinal:$0.transcriptOrigin == .local) },groupNames:Dictionary(uniqueKeysWithValues:state.organization.groups.map { ($0.id,$0.name) })) }.disabled(state.locked)
            }
            if state.cloudAccount.isSignedIn, let audio = state.libraryAudioSync {
                RecordAICard { LibraryAudioSyncPanel(engine:audio,choices:state.history.filter { $0.userId == state.cloudAccount.userId }.map { LibrarySyncChoice(id:$0.id,title:$0.title) }) }.disabled(state.locked)
            }
        }
    }

    private var accounts: some View {
        Group {
            RecordAIPageHeader(title: L10n.text("第三方账号"), subtitle: L10n.text("连接钉钉、飞书或 Notion，按需发送选定的转录内容。")) { EmptyView() }
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
