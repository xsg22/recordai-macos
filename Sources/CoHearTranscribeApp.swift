import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var miniController: MiniRecordingController?
    @MainActor func attach(_ state: AppState) {
        self.state = state
        if miniController == nil { miniController = MiniRecordingController(state: state) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { state?.showRecordingWindow() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { state?.prepareToQuit() == false ? .terminateCancel : .terminateNow }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { _ = BrowserAuthorizationCoordinator.receive(url) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { state?.locked != true && state?.miniMode != true }
    }

}

@main
struct CoHearTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup(id: "recordings") {
            MainView(state: state)
                .background(RecordingWindowObserver(state: state).frame(width: 0, height: 0))
                .onAppear { delegate.attach(state); NSApp.activate(ignoringOtherApps: true) }
                .frame(minWidth: 1040, minHeight: 760)
                .font(AppTypography.body)
                .controlSize(.extraLarge)
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音频…") { state.chooseAudio() }.keyboardShortcut("o").disabled(state.locked)
            }
            CommandGroup(replacing: .saveItem) {
                Button("导出会议 Markdown…") { state.export(kind: "Markdown") }.keyboardShortcut("s").disabled(state.current == nil)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("设置…") }.keyboardShortcut(",")
            }
            CommandMenu("RecordAI") {
                Button("打开执行追踪") { state.showExecutionTrace = true }
            }
        }
        MenuBarExtra(isInserted: Binding(get: { state.miniMode || state.recording || state.preparing || state.busy || state.recoveryBusy }, set: { _ in })) {
            RecordingMenuBarView(state: state)
        } label: {
            Label(state.recording ? (state.paused ? "录音已暂停" : "正在录音") : state.locked ? "正在处理录音" : "倾听转录", systemImage: state.recording ? (state.paused ? "pause.circle" : "record.circle") : "waveform")
        }
        Settings {
            RecordingAppConfigurationView(state: state)
        }
    }
}

struct MainView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var targeted = false
    @State private var delivering = false
    @State private var recovering = false
    @State private var showingExecution = false
    @FocusState private var editingTitle: Bool
    @State private var filter = "全部"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let accent = Color(red: 0.08, green: 0.35, blue: 0.95)
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(Color(red: 0.03, green: 0.08, blue: 0.23), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RecordAI").font(.system(size: 20, weight: .semibold))
                        Text("本地录音 · AI 转写").font(AppTypography.secondary).foregroundStyle(.secondary)
                    }
                }.padding(.top, 12)
                if state.current != nil {
                    Button { state.toggleRecording() } label: {
                        Label("新录音", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(accent).controlSize(.extraLarge).disabled(state.locked || state.syncing)
                    Button { state.chooseAudio() } label: { Label("导入音频…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                        .disabled(state.locked)
                }
                Picker("筛选录音", selection: $filter) {
                    Text("全部").tag("全部"); Text("已完成").tag("已完成"); Text("待处理").tag("待处理")
                }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                TextField("搜索录音和转录", text: $state.search).textFieldStyle(.roundedBorder)
                Text("录音库 · \(state.history.count)").font(AppTypography.secondary.weight(.semibold)).foregroundStyle(.secondary)
                List(selection: Binding(get: { state.selection }, set: { state.select($0) })) {
                    ForEach(state.filteredHistory.filter { filter == "全部" || (filter == "已完成" ? $0.status == .completed : $0.status != .completed) }) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.title).lineLimit(1).font(AppTypography.sidebar)
                                Spacer()
                                Image(systemName: record.status == .completed ? "checkmark.circle" : record.status == .recording ? "record.circle" : "clock").foregroundStyle(record.status == .completed ? accent : Color.orange).accessibilityLabel(record.status == .completed ? "已完成" : "待处理")
                            }
                            HStack {
                                Text(record.created, format: .dateTime.month().day().hour().minute())
                                Spacer()
                                if record.duration > 0 { Text(clock(record.duration)) }
                            }.font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).tag(record.id)
                    }
                }.listStyle(.sidebar).disabled(state.recording || state.preparing || state.recoveryBusy)
                SettingsLink {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                        Text("设置")
                        Spacer()
                        Image(systemName: "chevron.right").font(AppTypography.secondary)
                    }.font(AppTypography.body).frame(minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).help("转录、同步账号与本机Agent")
                Button { showingExecution = true } label: {
                    HStack(spacing: 10) { Image(systemName: "point.3.connected.trianglepath.dotted"); Text("执行追踪"); Spacer(); Image(systemName: "chevron.right").font(AppTypography.secondary) }
                        .font(AppTypography.body).frame(minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).help("查看采集、ASR、转录和Agent发布状态")

            }.padding(16).navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 340)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                if state.current != nil {
                    meetingToolbar
                    if let message = state.current?.recoveryMessage ?? state.current?.captureWarnings.last, !message.isEmpty, !state.recording {
                        HStack(alignment: .top) {
                            Label(message, systemImage: "exclamationmark.circle").font(AppTypography.secondary).foregroundStyle(.secondary)
                            Spacer()
                            if state.current?.pendingAudioFiles.isEmpty == false {
                                Button("继续转录") { state.transcribe() }.disabled(state.locked || state.model == nil)
                            }
                            Button("检查原轨…") { recovering = true }.disabled(state.locked)
                        }
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("开始你的下一段录音").font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text("会议、访谈或灵感，录下来再慢慢整理。").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    captureCard
                }
                if !state.syncStatus.isEmpty { compactSyncFeedback }
                if !state.speechModels.ready {
                    HStack {
                        Label(state.speechModels.busy ? "语音模型下载中 · \(Int(state.speechModels.progress * 100))%" : "首次使用需下载语音模型", systemImage: "arrow.down.circle")
                        Spacer()
                        Button(state.speechModels.busy ? "查看下载" : "下载模型…") { state.showModelDownload = true }
                    }.font(AppTypography.body).padding(12)
                        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if state.current == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield").foregroundStyle(accent)
                        Text("录音和语音识别在本机进行").font(AppTypography.secondary).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if state.recording { RecordingTransportView(state: state) }
                    else if state.audio != nil { NativePlaybackBar(state: state).controlSize(.regular) }
                    GeometryReader { geometry in
                        HStack(alignment: .top, spacing: 16) {
                            RecordingCanvasView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
                            if geometry.size.width >= 760 {
                                meetingInspector.frame(width: 250).frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Circle().fill(state.locked ? Color.orange : accent).frame(width: 6, height: 6)
                    Text(state.status).lineLimit(1)
                    Spacer()
                    if state.current != nil { Text("\(state.text.count) 字符") }
                }.font(AppTypography.secondary).foregroundStyle(.secondary)
            }.padding(20).background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { state.openRecordingWindow = { openWindow(id: "recordings") } }
        .sheet(isPresented: $recovering) { CaptureRecoveryView(state: state) }
        .sheet(isPresented: $state.showModelDownload) {
            VStack(alignment: .leading, spacing: 20) {
                ASRModelSetupView(store: state.speechModels)
                HStack { Spacer(); Button("关闭") { state.showModelDownload = false } }
            }.padding(28).frame(width: 520).controlSize(.large)
        }
        .sheet(isPresented: Binding(get: { showingExecution || state.showExecutionTrace }, set: { value in showingExecution = value; state.showExecutionTrace = value })) { RecordAIExecutionView(state: state) }
        .sheet(isPresented: $delivering) { RecordingDeliveryView(state: state) }
        .sheet(isPresented: $state.showSettings) { ConnectionsView(state: state) }
        .alert("需要处理", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            if state.error?.contains("没有可用的麦克风输入设备") == true {
                Button("选择系统声音") { state.recordingMode = .systemAudio; state.error = nil }
            }
            Button("好的") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }

    private var meetingInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("本机录音", systemImage: "lock.shield").font(AppTypography.secondary.weight(.semibold)).foregroundStyle(accent)
            Divider()
            Label("会议摘要", systemImage: "text.alignleft").font(AppTypography.heading)
            if state.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("尚无摘要。录音与转写内容会保留在本机。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView { Text(state.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Spacer(minLength: 0)
        }.font(AppTypography.secondary).padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 会议详情只保留一条工具栏，把可编辑内容作为窗口主体。
    private var meetingToolbar: some View {
        HStack(spacing: 12) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: { Image(systemName: "sidebar.left") }
                .help("显示或收起会议列表")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    TextField("录音标题", text: $state.title)
                        .textFieldStyle(.plain).font(.system(size: 20, weight: .semibold)).focused($editingTitle)
                        .onChange(of: state.title) { state.scheduleSave() }
                        .onSubmit { state.saveEdits(); editingTitle = false }
                    Button { editingTitle = true } label: { Image(systemName: "pencil").frame(width: 24, height: 28) }
                        .buttonStyle(.plain).help("编辑录音标题").accessibilityLabel("编辑录音标题")
                }
                if let record = state.current {
                    Text(record.created, format: .dateTime.year().month().day().hour().minute())
                        .font(AppTypography.secondary).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if state.busy {
                ProgressView().controlSize(.small)
                Button([TranscriptPhase.diarizing, .aligning].contains(state.transcriptPhase) ? "取消分析" : "取消转录") { state.cancel() }
            }
            if state.recording {
                LiveWaveformView(samples: Array(state.liveLevels.suffix(5)), tint: state.paused ? .secondary : .red).frame(width: 24, height: 22)
                Button { state.showMiniRecorder() } label: { Image(systemName: "pip.enter") }
                    .help("收起为 mini").accessibilityLabel("收起为 mini")
            }
            Menu {
                Picker("录音音源", selection: $state.recordingMode) {
                    ForEach(MeetingRecordingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.disabled(state.locked)
                Picker("转写语言", selection: $state.language) {
                    Text("中文").tag("zh"); Text("中英自动").tag("auto")
                    Text("英语").tag("en")
                }.disabled(state.locked)
                Divider()
                Picker("录音模式", selection: $state.recordingProfile) {
                    ForEach(RecordingProfile.allCases) { Text($0.title).tag($0) }
                }.disabled(state.locked)
            } label: { Image(systemName: "slider.horizontal.3") }
                .help("录音音源与转写语言")
            if !state.recording {
                Button { state.continueRecording() } label: { Label("继续录音", systemImage: "mic") }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(state.locked || state.syncing)
            }
            Button { delivering = true } label: { Label("交付", systemImage: "square.and.arrow.up") }
                .disabled(state.current == nil)
            Button { showingExecution = true } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .help("执行追踪").accessibilityLabel("执行追踪")
            Menu {
                Button("新会议录音") { state.toggleRecording() }.disabled(state.locked || state.syncing)
                Divider()
                Button("复制会议 Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.markdown, forType: .string)
                }
                Button("导出会议 Markdown…") { state.export(kind: "Markdown") }
                Button("导出转录 TXT…") { state.export(kind: "文本") }
                Button("导出原始字幕 SRT…") { state.export(kind: "字幕") }.disabled(state.current?.subtitles.isEmpty ?? true)
                Divider()
                if state.busy { Button([TranscriptPhase.diarizing, .aligning].contains(state.transcriptPhase) ? "取消分析" : "取消转录") { state.cancel() } }
                else {
                    Button(state.current?.pendingAudioFiles.isEmpty == false ? "继续转录" : (state.current?.text.isEmpty == false ? "重新转录" : "开始转录")) { state.transcribe() }
                        .disabled(state.audio == nil || state.model == nil || state.recording || state.preparing)
                }
                Divider()
                Button("恢复中断录音…") { recovering = true }.disabled(state.locked)
                Button("移到废纸篓…", role: .destructive) { state.deleteCurrent() }.disabled(state.locked)
            } label: { Image(systemName: "ellipsis") }.help("导出及更多操作")
        }.controlSize(.large).frame(minHeight: 48)
    }

    private var compactSyncFeedback: some View {
        HStack(spacing: 8) {
            Image(systemName: state.syncing ? "arrow.triangle.2.circlepath" : "info.circle.fill")
            Text(state.syncStatus).lineLimit(1)
            Spacer()
            if let url = state.remoteURL { Link("打开文档", destination: url) }
            if !state.syncing {
                Button { state.syncStatus = ""; state.syncReceipt = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }.font(AppTypography.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("准备录音").font(AppTypography.heading)
                    Text(recordingConfigurationSummary).font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { state.toggleRecording() } label: { Label("开始录音", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(state.locked || state.syncing)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("录音会话").font(AppTypography.secondary.weight(.semibold)).foregroundStyle(.secondary)
                Picker("录音会话", selection: $state.recordingSessionMode) {
                    ForEach(RecordingSessionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(state.locked)
                Text(state.recordingSessionMode.detail).font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { state.chooseAudio() } label: { Label("导入音频…", systemImage: "square.and.arrow.down") }
                    .disabled(state.locked)
                Text("也可将音频拖入此处").font(AppTypography.secondary).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu {
                    Picker("音源", selection: $state.recordingMode) {
                        ForEach(MeetingRecordingMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("语言", selection: $state.language) {
                        Text("中文").tag("zh"); Text("中英自动").tag("auto"); Text("英语").tag("en")
                    }
                    Picker("录音模式", selection: $state.recordingProfile) {
                        ForEach(RecordingProfile.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label("录音设置", systemImage: "slider.horizontal.3") }
                    .disabled(state.locked).help("修改音源、转写语言和录音模式")
            }
        }.padding(24).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(targeted ? accent : .gray.opacity(0.15), lineWidth: targeted ? 2 : 1))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard !state.locked, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in state.useAudio(url) } } }
                return true
            }
    }
    private var recordingConfigurationSummary: String {
        let language = state.language == "zh" ? "中文" : state.language == "en" ? "英语" : "中英自动"
        let profile = state.recordingProfile == .realtime ? "实时转录" : state.recordingProfile == .backgroundRealtime ? "后台实时" : "仅录音 · 录完转录"
        return [state.recordingMode.title, language, profile].joined(separator: " · ")
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct ConnectionsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("连接个人工作区").font(.system(size: 22, weight: .semibold)); Spacer(); Button("完成") { dismiss() } }
            Text("登录你的账号，会议完成后即可保存到个人文档或发给自己。无需填写服务地址、密钥或技术参数。")
                .foregroundStyle(.secondary)
            Picker("平台", selection: $state.syncDestination) {
                ForEach(PersonalDestination.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            AccountConnectionPanel(state: state)
            Spacer()
        }.padding(26).frame(width: 740, height: 560).font(AppTypography.body).controlSize(.extraLarge)
    }
}

struct SyncReviewView: View {
    @ObservedObject var state: AppState
    let close: () -> Void
    @State private var connecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("同步这场会议").font(.system(size: 22, weight: .semibold)); Spacer(); Button("关闭") { close() }.disabled(state.syncing) }
            Picker("同步到", selection: $state.syncDestination) {
                ForEach(PersonalDestination.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(state.syncing)
            AccountConnectionPanel(state: state, compact: true)
            if state.syncDestination == .dingtalk {
                DingTalkNotificationOption(account: state.dingTalkAccount, disabled: state.syncing)
            }
            Text("发送内容：录音名称、时间、时长和转录正文。原始音频不会发送。")
                .font(AppTypography.body).foregroundStyle(.secondary)
            ScrollView { Text(state.markdown).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(14).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            if !state.syncStatus.isEmpty { Text(state.syncStatus).font(AppTypography.secondary).foregroundStyle(.secondary) }
            if !state.syncReceipt.isEmpty {
                DisclosureGroup("查看 MCP 回执") {
                    ScrollView { Text(state.syncReceipt).font(AppTypography.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                }
            }
            if let url = state.remoteURL { Link("查看远端结果", destination: url) }
            HStack {
                Button("连接账号") { connecting = true }.disabled(state.syncing)
                Spacer()
                if state.syncing { ProgressView().controlSize(.small) }
                Button("同步到\(state.syncDestination.rawValue)") { state.syncMeeting() }
                    .buttonStyle(.borderedProminent).disabled(!state.canSyncFinalTranscript || !accountReady)
            }
        }.padding(26).frame(width: 780, height: 700).font(AppTypography.body).controlSize(.extraLarge)
        .sheet(isPresented: $connecting) { ConnectionsView(state: state) }
        .alert("同步结果", isPresented: Binding(get: { state.syncFeedback != nil }, set: { if !$0 { state.syncFeedback = nil } })) {
            if let url = state.remoteURL { Button("打开文档") { NSWorkspace.shared.open(url); state.syncFeedback = nil } }
            Button("知道了") { state.syncFeedback = nil }
        } message: { Text(state.syncFeedback ?? "") }
    }
    private var accountReady: Bool {
        switch state.syncDestination {
        case .dingtalk: return state.dingTalkAccount.connected
        case .notion: return state.notionAccount.connected
        case .feishu: return state.feishuAccount.connected
        }
    }

}

struct SyncTargetStatus: View {
    @ObservedObject var store: MCPConnectionStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(store.connected ? "已连接" : "尚未连接", systemImage: store.connected ? "checkmark.circle.fill" : "link")
            Text(store.targetDescription).font(AppTypography.secondary).foregroundStyle(.secondary)
        }
    }
}
