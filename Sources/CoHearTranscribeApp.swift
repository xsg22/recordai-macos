import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSLog

private let feedbackDiagnosticLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.xsg.talktuck", category: "FeedbackDiagnostics")

/// A hidden login-item launch may never install a SwiftUI window's StateObject.
/// Keep application services alive independently of that presentation lifecycle.
@MainActor private enum ApplicationServices {
    static let state = AppState()
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var miniController: MiniRecordingController?
    @MainActor func attach(_ state: AppState) {
        self.state = state
        if miniController == nil { miniController = MiniRecordingController(state: state) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        attach(ApplicationServices.state)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let state else { return true }
        guard state.mainWindow != nil || state.openRecordingWindow != nil else { return true }
        state.showRecordingWindow()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = BrowserAuthorizationCoordinator.receive(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        state?.locked != true && state?.miniMode != true
    }

}

@main
struct CoHearTranscribeApp: App {
    @ObservedObject private var appLanguage: AppLanguage
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state: AppState
    init() {
        AppAppearance.shared.apply()
        _appLanguage = ObservedObject(wrappedValue: AppLanguage.shared)
        // Construct eagerly: StateObject's autoclosure may otherwise wait for
        // the first window, leaving a background launch without account services.
        let appState = ApplicationServices.state
        _state = StateObject(wrappedValue: appState)
    }
    var body: some Scene {
        WindowGroup(id: "recordings") {
            MainView(state: state)
                .environment(\.locale, appLanguage.locale)
                .background(RecordingWindowObserver(state: state).frame(width: 0, height: 0))
                .frame(minWidth: 1040, minHeight: 760)
                .font(AppTypography.body)
                .controlSize(.extraLarge)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("导入音频…")) { state.chooseAudio() }.keyboardShortcut("o").disabled(state.locked)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.text("导出转录 Markdown…")) { state.export(kind: "Markdown") }.keyboardShortcut("s").disabled(state.current == nil)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(L10n.text("设置…")) }.keyboardShortcut(",")
            }
        }
        MenuBarExtra(isInserted: Binding(get: { state.miniMode || state.recording || state.preparing || state.busy || state.recoveryBusy }, set: { _ in })) {
            RecordingMenuBarView(state: state)
        } label: {
            Label(L10n.text(state.recording ? (state.paused ? "录音已暂停" : state.recordingIsMuted ? "静音录制" : "正在录音") : state.locked ? "正在处理录音" : "TalkTuck"), systemImage: state.recording ? (state.paused ? "pause.circle" : "record.circle") : "waveform")
        }
        Settings {
            RecordingAppConfigurationView(state: state)
                .environment(\.locale, appLanguage.locale)
        }
    }
}

struct MainView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var targeted = false
    @State private var delivering = false
    @State private var recovering = false
    @State private var managingCollections = false
    @State private var batchMode = false
    @State private var batchIDs = Set<UUID>()
    @FocusState private var editingTitle: Bool
    @State private var showingFeedback = false
    @State private var showingAccount = false
    @State private var filter = "全部"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var windowWidth: CGFloat = 1440
    init(state: AppState, initialFilter: String = "全部") {
        self.state = state; _filter = State(initialValue: initialFilter)
    }
    private let accent = TalkTuckTheme.accent
    private var missingMicrophone: Bool { state.error?.contains("没有可用的麦克风输入设备") == true }
    private var visibleHistory: [MeetingRecord] {
        state.filteredHistory.filter { filter == "全部" || filter == "回收站" || (filter == "星标" ? $0.isStarred : filter == "已完成" ? $0.status == .completed : $0.status != .completed) }
    }
    private var emptyFilter: Bool { filter != "回收站" && (!state.search.isEmpty || filter != "全部" || !state.groupFilter.isEmpty) && visibleHistory.isEmpty }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TalkTuckLogo()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TalkTuck").font(.system(size: 20, weight: .semibold))
                        Text(L10n.text("本地录音 · AI 转写")).font(AppTypography.secondary).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 8)
                Button { showNewRecordingSetup() } label: {
                    Label(L10n.text("开始新录音"), systemImage: "mic").frame(maxWidth: .infinity)
                }.buttonStyle(TalkTuckPrimaryButtonStyle()).disabled(state.locked || state.syncing || missingMicrophone)
                VStack(spacing: 3) {
                    filterRow("全部", symbol: "waveform", count: state.history.count)
                    filterRow("星标", symbol: "star", count: state.history.filter(\.isStarred).count)
                    filterRow("回收站", symbol: "trash", count: state.trashedHistory.count)
                }.padding(.top, 4)
                organizationFilters
                if state.recording && !state.isViewingRecording {
                    Button {
                        filter = "全部"
                        state.returnToRecording()
                    } label: {
                        Label(L10n.text("返回正在录音"), systemImage: "record.circle.fill")
                            .font(AppTypography.secondary).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.horizontal, 10).accessibilityLabel(L10n.text("返回正在录音"))
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(TalkTuckTheme.muted).accessibilityHidden(true)
                    TextField(L10n.text("搜索录音名称或内容…"), text: $state.search).textFieldStyle(.plain).font(.system(size: 13))
                }.padding(12).background(TalkTuckTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(TalkTuckTheme.border))
                HStack {
                    Text(L10n.text("录音资料库")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text(batchMode ? "完成" : "选择")) { batchMode.toggle(); batchIDs = [] }.buttonStyle(.plain).font(AppTypography.secondary).disabled(state.locked || filter == "回收站").accessibilityLabel(L10n.text(batchMode ? "完成批量整理" : "批量整理"))
                    Menu {
                        Button(L10n.text("全部录音")) { filter = "全部" }
                        Button(L10n.text("已完成")) { filter = "已完成" }
                        Button(L10n.text("待处理")) { filter = "待处理" }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.text("按处理状态筛选"))
                }.padding(.top, 8).padding(.horizontal, 10)
                batchToolbar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleHistory) { record in
                        HStack(spacing: 2) {
                            if batchMode {
                                Toggle(L10n.text("选择 \(record.title)"), isOn: Binding(get: { batchIDs.contains(record.id) }, set: { if $0 { batchIDs.insert(record.id) } else { batchIDs.remove(record.id) } }))
                                    .labelsHidden().toggleStyle(.checkbox).disabled(state.locked)
                            }
                            Button { if filter == "回收站" { filter = "全部" }; state.select(record.id) } label: {
                                RecordingLibraryRow(record: record, selected: state.selection == record.id, metadata: libraryMetadata(record), groupName: state.organization.group(record.groupID)?.name)
                            }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .contextMenu { recordingMenu(record) }
                        }.accessibilityAddTraits(state.selection == record.id ? .isSelected : [])
                            .accessibilityLabel(record.title + ", " + L10n.text(record.status == .completed ? "已完成，" : "待处理，") + libraryMetadata(record) + (state.organization.group(record.groupID).map { ", " + $0.name } ?? ""))
                    }
                    }
                }.focusable().focusEffectDisabled().onMoveCommand { direction in
                    guard state.canBrowseRecordings, !visibleHistory.isEmpty else { return }
                    let current = visibleHistory.firstIndex(where: { $0.id == state.selection }) ?? -1
                    if direction == .down { state.select(visibleHistory[min(visibleHistory.count - 1, current + 1)].id) }
                    if direction == .up { state.select(visibleHistory[max(0, current - 1)].id) }
                }.frame(minHeight: 0, maxHeight: .infinity).layoutPriority(-1)
                    .disabled(!state.canBrowseRecordings)
                HStack(spacing: 16) {
                    SettingsLink { Label(L10n.text("设置"), systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 32, alignment: .leading) }
                        .buttonStyle(.plain).help(L10n.text("录音、TalkTuck 账号、第三方账号与 Agent"))
                }.font(AppTypography.secondary).fixedSize(horizontal: false, vertical: true)

            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(TalkTuckTheme.sidebar)
                .navigationSplitViewColumnWidth(windowWidth <= 1100 ? 260 : 280)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                if filter == "回收站" {
                    RecordingTrashView(state: state) { filter = "全部" }
                } else if emptyFilter {
                    VStack(spacing: 24) {
                        Image(systemName: state.search.isEmpty && filter == "星标" ? "star" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(accent)
                            .frame(width: 100, height: 110)
                            .background(LinearGradient(colors: [TalkTuckTheme.surface, accent.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(TalkTuckTheme.border, lineWidth: 1))
                            .rotationEffect(.degrees(-7)).shadow(color: accent.opacity(0.06), radius: 14, y: 10).padding(.bottom, 8)
                        Text(L10n.text(filter == "星标" && state.groupFilter.isEmpty && state.search.isEmpty ? "暂无星标录音" : "没有找到相关录音")).font(.system(size: 23, weight: .semibold))
                        Text(L10n.text("调整搜索或分组筛选，也可以导入新的音频。"))
                            .font(AppTypography.body).foregroundStyle(.secondary)
                        Button(L10n.text(state.search.isEmpty ? "查看全部录音" : "清除搜索")) { state.search = ""; state.groupFilter = ""; filter = "全部" }.buttonStyle(TalkTuckPrimaryButtonStyle())
                    }.padding(.top, 100).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                if missingMicrophone {
                    Spacer(minLength: 12)
                    missingMicrophoneView
                } else if state.current != nil {
                    meetingToolbar
                    if state.canShowAgentOnboarding && !delivering && !recovering && !showingAccount {
                        TalkTuckCard(quiet: true) { AgentConnectionView(state: state, onboarding: true) }
                    }
                    if let issue = state.recordingIssue, state.isViewingRecording {
                        HStack(spacing: 16) {
                            Label(L10n.text(issue), systemImage: "exclamationmark.triangle")
                            Text(L10n.text("已有录音已保留。"))
                            if state.canRetryMicrophone { Button(L10n.text("重试并继续")) { state.pauseRecording() } }
                            Button(L10n.text("停止并保存")) { state.toggleRecording() }
                            Spacer(minLength: 0)
                        }.font(AppTypography.secondary).foregroundStyle(.orange).padding(14)
                            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    } else if state.busy && state.isViewingActiveTask {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(L10n.processingStatus(state.status) + L10n.text(" · 音频已保存，可取消处理后稍后重试。"))
                            Button(L10n.text([TranscriptPhase.diarizing, .aligning].contains(state.transcriptPhase) ? "取消分析" : "取消转录")) { state.cancel() }
                            Spacer(minLength: 0)
                        }.font(AppTypography.secondary).foregroundStyle(accent).padding(14)
                            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let message = state.current?.recoveryMessage ?? state.current?.captureWarnings.last, !message.isEmpty, !state.isViewingRecording {
                        HStack(alignment: .top) {
                            Label(L10n.text(message), systemImage: "exclamationmark.circle").font(AppTypography.secondary).foregroundStyle(.secondary)
                            Spacer()
                            if state.current?.pendingAudioFiles.isEmpty == false {
                                Button(L10n.text("继续转录")) { state.transcribe() }.disabled(state.locked || state.model == nil)
                            }
                            Button(L10n.text("检查原轨…")) { recovering = true }.disabled(state.locked)
                        }
                    }
                } else {
                    Spacer(minLength: 12)
                    captureCard.frame(maxWidth: 438).frame(maxWidth: .infinity)
                }
            if !state.syncStatus.isEmpty { compactSyncFeedback }
                if !state.speechModels.ready && state.current != nil && !missingMicrophone { modelDownloadBanner }
                if missingMicrophone {
                    Spacer(minLength: 0)
                } else if state.current == nil {
                    Spacer(minLength: 12)
                } else {
                    MeetingReadingView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if state.current != nil && (state.locked || state.transcriptPhase == .failed || state.agentPublicationError != nil || state.status.hasPrefix("已重试")) {
                HStack(spacing: 8) {
                    Circle().fill(state.locked ? Color.orange : accent).frame(width: 6, height: 6)
                    Text(L10n.processingStatus(state.status)).lineLimit(1)
                    Spacer()
                    if state.current != nil { Text(L10n.text("\(state.text.count) 字符")) }
                }.font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                }
            }.padding(28).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).background(TalkTuckTheme.surface)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingFeedback = true } label: {
                    Label(L10n.text("意见反馈"), systemImage: "headphones")
                }.help(L10n.text("意见反馈"))
                TalkTuckAccountToolbarButton(store: state.cloudAccount) { showingAccount = true }
            }
        }
        .sheet(isPresented: $showingFeedback) { FeedbackMailView() }
        .sheet(isPresented: $showingAccount) {
            VStack(alignment: .trailing, spacing: 0) {
                Button(L10n.text("完成")) { showingAccount = false }
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 16).padding(.trailing, 20)
                RecordingAppConfigurationView(state: state, initialSection: "talktuck")
            }
        }
        .overlay(alignment: .bottom) {
            if state.recording && !state.miniMode && (state.showsInlineRecorder || emptyFilter || filter == "回收站") && !missingMicrophone, let controller = state.miniController {
                MiniRecordingView(state: state, controller: controller, inline: true).padding(.bottom, 28)
                    .onAppear { state.setInlineRecorderVisible(true) }
                    .onDisappear { state.setInlineRecorderVisible(false) }
            }
        }
        .buttonStyle(TalkTuckSecondaryButtonStyle())
        .tint(TalkTuckTheme.accent)
        .foregroundStyle(TalkTuckTheme.ink)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { windowWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in windowWidth = width }
        })
        .onAppear { state.openRecordingWindow = { openWindow(id: "recordings") }; feedbackDiagnosticLog.notice("Main window opened") }
        .onChange(of: state.recording) { _, recording in feedbackDiagnosticLog.notice("Recording active: \(recording, privacy: .public)") }
        .onChange(of: state.busy) { _, busy in feedbackDiagnosticLog.notice("Processing active: \(busy, privacy: .public)") }
        .onChange(of: state.recordingNavigationRevision) { filter = "全部"; batchMode = false }
        .sheet(isPresented: $managingCollections) { CollectionManager(state: state) }
        .onChange(of: state.history.map(\.id)) { batchIDs.formIntersection(Set(state.history.map(\.id))) }
        .sheet(isPresented: $recovering) { CaptureRecoveryView(state: state) }
        .sheet(isPresented: $state.showModelDownload) {
            VStack(alignment: .leading, spacing: 20) {
                ASRModelSetupView(store: state.speechModels, close: { state.showModelDownload = false })
            }.padding(28).frame(width: 720).controlSize(.large)
        }
        .sheet(isPresented: $delivering) { RecordingDeliveryView(state: state) }
        .sheet(item: $state.deletionRequest) { record in ConfirmTrashView(state: state, record: record) }
        .sheet(isPresented: $state.showSettings) { ConnectionsView(state: state) }
        .sheet(isPresented: Binding(get: { state.error != nil && !missingMicrophone }, set: { if !$0 && !missingMicrophone { state.error = nil } })) {
            TalkTuckErrorView(message: state.error ?? "", close: { state.error = nil }, retry: state.errorRetry == nil ? nil : { state.retryLastError() })
        }
    }

    private var organizationFilters: some View {
        HStack(spacing: 8) {
            Picker(L10n.text("分组筛选"), selection: $state.groupFilter) {
                Text(L10n.text("所有分组")).tag("")
                Text(L10n.text("未分组")).tag("ungrouped")
                ForEach(state.organization.groups) { Text($0.name).tag($0.id.uuidString) }
            }.pickerStyle(.menu).labelsHidden().accessibilityLabel(L10n.text("分组筛选")).frame(maxWidth: .infinity).disabled(!state.canBrowseRecordings)
            if !state.groupFilter.isEmpty {
                Button { state.groupFilter = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel(L10n.text("清除分组筛选"))
            }
            Button { managingCollections = true } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain).accessibilityLabel(L10n.text("管理分组")).disabled(state.locked)
        }.font(AppTypography.secondary)
    }
    @ViewBuilder private var batchToolbar: some View {
        if batchMode {
            HStack {
                Text(L10n.text("已选 \(batchIDs.count)")).foregroundStyle(.secondary)
                Button(L10n.text("全选当前")) { batchIDs = Set(visibleHistory.map(\.id)) }
                Menu(L10n.text("移动到")) { organizeMenu(ids: batchIDs) }.disabled(batchIDs.isEmpty)
            }.font(AppTypography.secondary).disabled(state.locked || filter == "回收站")
        }
    }
    @ViewBuilder private func organizeMenu(ids: Set<UUID>) -> some View {
        Button(L10n.text("未分组")) { _ = state.setGroup(nil, recordIDs: ids) }
        ForEach(state.organization.groups.filter { group in state.history.filter { ids.contains($0.id) }.allSatisfy { $0.userId == group.userId } }) { group in Button(group.name) { _ = state.setGroup(group.id, recordIDs: ids) } }
    }
    @ViewBuilder private func recordingMenu(_ record: MeetingRecord) -> some View {
        if state.trashedHistory.contains(where: { $0.id == record.id }) {
            Button(L10n.text("恢复录音")) { _ = state.restoreTrash(record.id) }.disabled(state.locked)
        } else {
            Button(L10n.text(record.isStarred ? "取消星标" : "添加星标")) { state.toggleStar(recordingID: record.id) }.disabled(state.locked)
            Menu(L10n.text("移动到分组")) {
                Button { _ = state.setGroup(nil, recordIDs: [record.id]) } label: {
                    Label(L10n.text("未分组"), systemImage: record.groupID == nil ? "checkmark" : "folder")
                }
                ForEach(state.organization.groups.filter { $0.userId == record.userId }) { group in
                    Button { _ = state.setGroup(group.id, recordIDs: [record.id]) } label: {
                        Label(group.name, systemImage: record.groupID == group.id ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button(L10n.text("管理分组")) { managingCollections = true }
            }.disabled(state.locked)
            Menu(L10n.text("导出")) {
                ForEach(["文本", "Markdown", "JSON", "字幕"], id: \.self) { kind in
                    Button(L10n.text(kind == "字幕" ? "原始 SRT" : kind == "文本" ? "TXT" : kind)) {
                        state.export(kind: kind, recordingID: record.id)
                    }.disabled(kind == "字幕" && record.subtitles.isEmpty)
                }
                Divider()
                Button(L10n.text("全部音频")) { state.exportAudio(recordingID: record.id) }.disabled(record.audioFiles.isEmpty)
            }.disabled(state.locked)
            Divider()
            Button(L10n.text("移到回收站…"), role: .destructive) { state.requestTrash(record.id) }.disabled(state.locked)
        }
    }

    private func filterRow(_ title: String, symbol: String, count: Int) -> some View {
        Button { if title == "回收站" { state.select(nil) }; filter = title } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(L10n.text(title == "全部" ? "全部录音" : title))
                Spacer()
                Text("\(count)").foregroundStyle(TalkTuckTheme.muted)
            }.font(.system(size: 14, weight: filter == title ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 12)
                .contentShape(Rectangle())
                .background(filter == title ? TalkTuckTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).foregroundStyle(filter == title ? accent : .primary).disabled(!state.canBrowseRecordings)
    }

    private var missingMicrophoneView: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.slash.fill").font(.system(size: 30)).foregroundStyle(.red)
                .frame(width: 76, height: 76).background(Color.red.opacity(0.1), in: Circle())
            Text(L10n.text("未找到麦克风")).font(.system(size: 24, weight: .semibold))
            Text(L10n.text("无法检测到可用的麦克风设备。请连接麦克风，\n或选择其他音源，也可在系统设置中检查输入设备。"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { state.recordingMode = .systemAudio; state.error = nil } label: {
                recoveryChoice("录制系统声音", detail: "录制线上会议、视频或电脑播放的声音", symbol: "desktopcomputer")
            }.buttonStyle(.plain)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
            } label: {
                recoveryChoice("打开声音设置", detail: "检查麦克风并选择可用的输入设备", symbol: "gearshape")
            }.buttonStyle(.plain)
            TalkTuckInfo(text: L10n.text("已有录音和文字会保留。设备恢复后可继续录音。"))
            Button(L10n.text("返回")) { state.error = nil }
        }.frame(maxWidth: 430).frame(maxWidth: .infinity).padding(32)
    }

    private func recoveryChoice(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(accent)
                .frame(width: 48, height: 48).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title)).font(AppTypography.body.weight(.semibold))
                Text(L10n.text(detail)).font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(TalkTuckTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 会议详情只保留一条工具栏，把可编辑内容作为窗口主体。
    private var meetingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { meetingTitle.frame(minWidth: 220); meetingActions.fixedSize() }
            VStack(alignment: .leading, spacing: 16) { meetingTitle; HStack { Spacer(); meetingActions } }
        }.controlSize(.large).padding(.bottom, 21)
    }
    private var meetingTitle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    TextField(L10n.text("录音标题"), text: $state.title)
                        .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold)).focused($editingTitle)
                        .frame(width: min(360, max(110, (state.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold)]).width + 6)))
                        .onChange(of: state.title) { state.scheduleSave() }
                        .onSubmit { state.saveEdits(); editingTitle = false }
                    Button { editingTitle = true } label: { Image(systemName: "pencil").frame(width: 24, height: 28) }
                        .buttonStyle(.plain).help(L10n.text("编辑录音标题")).accessibilityLabel(L10n.text("编辑录音标题"))
            Button { state.toggleStar() } label: { Image(systemName: state.current?.isStarred == true ? "star.fill" : "star") }
                .buttonStyle(.plain).foregroundStyle(state.current?.isStarred == true ? accent : .secondary)
                .disabled(state.locked).help(L10n.text(state.current?.isStarred == true ? "取消星标" : "添加星标"))
                .accessibilityLabel(L10n.text(state.current?.isStarred == true ? "取消星标" : "添加星标"))
                    Spacer(minLength: 0)
                }
                if let record = state.current {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            meetingMetadata(record)
                            RecordingGroupMenu(state: state)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            meetingMetadata(record)
                            RecordingGroupMenu(state: state)
                        }
                    }.font(AppTypography.secondary).foregroundStyle(TalkTuckTheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func meetingMetadata(_ record: MeetingRecord) -> some View {
        HStack(spacing: 10) {
            Text(record.created, format: .dateTime.year().month().day().locale(L10n.locale))
            if state.isViewingRecording {
                Text(record.created, format: .dateTime.hour().minute().locale(L10n.locale))
                Text(L10n.text("· 录音中"))
            } else {
                (Text(record.created, format: .dateTime.hour().minute().locale(L10n.locale)) + Text("—") + Text(record.created.addingTimeInterval(record.duration), format: .dateTime.hour().minute().locale(L10n.locale)))
                Text("· " + recordingDurationText(record.duration))
            }
            Text("· " + L10n.text("转录语言") + "：" + (TranscriptionLanguage(rawValue: record.language)?.title ?? (record.language == "yue" ? L10n.text("粤语") : record.language)))
                .accessibilityIdentifier("detail-transcription-language")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func libraryMetadata(_ record: MeetingRecord) -> String {
        if state.recording, record.id == state.activeRecordingID {
            return L10n.text(state.paused ? "录音已暂停" : "正在录音") + " · " + recordingDurationText(Double(state.elapsed))
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        if Calendar.current.isDateInToday(record.created) { formatter.dateFormat = L10n.text("今天 HH:mm") }
        else if Calendar.current.isDateInYesterday(record.created) { formatter.dateFormat = L10n.text("昨天 HH:mm") }
        else { formatter.dateFormat = L10n.text("M月d日") }
        return formatter.string(from: record.created) + (record.duration > 0 ? " · " + recordingDurationText(record.duration) : "")
    }
    private var meetingActions: some View {
        HStack(spacing: 8) {
            if state.isViewingRecording {
                LiveWaveformView(samples: Array(state.liveLevels.suffix(5)), tint: state.paused || state.recordingIsMuted ? .secondary : .red).frame(width: 24, height: 22)
                Button { state.showMiniRecorder() } label: { Image(systemName: "pip.enter") }
                    .help(L10n.text("收起为 mini")).accessibilityLabel(L10n.text("收起为 mini"))
            }
            if !state.recording {
                if state.audio != nil && (state.text.isEmpty || state.current?.pendingAudioFiles.isEmpty == false) {
                    Button { state.transcribe() } label: {
                        Label(L10n.text(state.current?.pendingAudioFiles.isEmpty == false ? "继续转录" : "开始转录"), systemImage: "waveform")
                    }.buttonStyle(TalkTuckPrimaryButtonStyle()).disabled(state.locked || state.syncing)
                } else {
                    Button { state.continueRecording() } label: { Label(L10n.text("继续录音"), systemImage: "mic") }
                        .buttonStyle(TalkTuckPrimaryButtonStyle()).disabled(state.locked || state.syncing)
                }
            }
            Button { delivering = true } label: { Label(L10n.text("导出"), systemImage: "square.and.arrow.up") }
                .disabled(state.current == nil)
            Menu {
                Button(L10n.text(state.editingTranscript ? "完成全文编辑" : "编辑全文")) { state.editingTranscript.toggle() }.disabled(state.locked)
                Button(L10n.text("导入音频…")) { state.chooseAudio() }.disabled(state.locked)
                Menu(L10n.text("录音设置")) {
                    Picker(L10n.text("音源"), selection: $state.recordingMode) { ForEach(MeetingRecordingMode.allCases) { Text($0.title).tag($0) } }
                    Picker(L10n.text("转录语言"), selection: $state.language) { ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0.rawValue) } }
                    Picker(L10n.text("录音模式"), selection: $state.recordingProfile) { ForEach(RecordingProfile.allCases) { Text($0.title).tag($0) } }
                }.disabled(state.locked)
                Divider()
                Button(L10n.text("继续录音")) { state.continueRecording() }.disabled(state.locked || state.syncing)
                Button(L10n.text("开始新录音")) { showNewRecordingSetup() }.disabled(state.locked || state.syncing)
                Divider()
                Button(L10n.text("复制转录 Markdown")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.markdown, forType: .string)
                }
                Button(L10n.text("导出转录 Markdown…")) { state.export(kind: "Markdown") }
                Button(L10n.text("导出转录 TXT…")) { state.export(kind: "文本") }
                Button(L10n.text("导出原始字幕 SRT…")) { state.export(kind: "字幕") }.disabled(state.current?.subtitles.isEmpty ?? true)
                Divider()
                if state.busy { Button(L10n.text([TranscriptPhase.diarizing, .aligning].contains(state.transcriptPhase) ? "取消分析" : "取消转录")) { state.cancel() } }
                else {
                    Button(L10n.text(state.current?.pendingAudioFiles.isEmpty == false ? "继续转录" : (state.current?.text.isEmpty == false ? "重新转录" : "开始转录"))) { state.transcribe() }
                        .disabled(state.audio == nil || state.model == nil || state.recording || state.preparing)
                }
                Divider()
                Button(L10n.text("恢复中断录音…")) { recovering = true }.disabled(state.locked)
                Button(L10n.text("移到回收站…"), role: .destructive) { state.deleteCurrent() }.disabled(state.locked)
            } label: { Image(systemName: "ellipsis") }.help(L10n.text("导出及更多操作"))
        }
    }

    private var compactSyncFeedback: some View {
        HStack(spacing: 8) {
            Image(systemName: state.syncing ? "arrow.triangle.2.circlepath" : "info.circle.fill")
            Text(L10n.text(state.syncStatus)).lineLimit(1)
            Spacer()
            if let url = state.remoteURL { Link("打开文档", destination: url) }
            if !state.syncing {
                Button { state.syncStatus = ""; state.syncReceipt = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }.font(AppTypography.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelDownloadBanner: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            Text(L10n.text(state.speechModels.busy ? "语音模型下载中 · \(Int(state.speechModels.progress * 100))%" : "首次使用需要下载语音模型"))
            Button(L10n.text(state.speechModels.busy ? "查看下载" : "下载模型 ↗")) { state.showModelDownload = true }.buttonStyle(.plain).foregroundStyle(accent)
            Spacer(minLength: 0)
        }.font(.system(size: 12)).foregroundStyle(TalkTuckTheme.muted).padding(16)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func showNewRecordingSetup() {
        state.select(nil)
        guard state.selection == nil else { return }
        filter = "全部"
        state.search = ""
        state.groupFilter = ""
    }

    private var captureCard: some View {
        VStack(alignment: .center, spacing: 18) {
            Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(accent)
                .frame(width: 100, height: 112).background(TalkTuckTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.08))).rotationEffect(.degrees(-7))
                .shadow(color: accent.opacity(0.08), radius: 18, y: 12).padding(.bottom, 12)
            Text(L10n.text(state.history.isEmpty ? "开始你的第一段录音" : "开始一段新录音")).font(.system(size: 27, weight: .semibold))
            Text(L10n.text("会议、访谈、课程、灵感…\nTalkTuck 帮你录音、转写和整理，\n让重要的内容不再遗漏。"))
                .font(.system(size: 14)).lineSpacing(9).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8).padding(.bottom, 14)
            Button { state.toggleRecording() } label: {
                Label(L10n.text("开始录音"), systemImage: "mic").frame(maxWidth: .infinity)
            }
            .buttonStyle(TalkTuckPrimaryButtonStyle()).disabled(state.locked || state.syncing)
            Menu { recordingSettingsMenu } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text(L10n.text("录音设置"))
                    Text(recordingConfigurationSummary).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(appLanguage.effective).disabled(state.locked)
            .help(L10n.text("录音设置")).accessibilityLabel(L10n.text("录音设置"))
            HStack(alignment: .top, spacing: 14) {
                Button { state.chooseAudio() } label: { homeChoice("导入音频", detail: "支持 MP3、M4A、WAV\n常用音频格式", symbol: "doc.badge.plus") }.disabled(state.locked)
                Button { state.recordingMode = .systemAudio; state.toggleRecording() } label: { homeChoice("录制系统声音", detail: "录制线上会议、视频\n或电脑播放的声音", symbol: "desktopcomputer") }.disabled(state.locked || state.syncing)
            }
            .buttonStyle(.plain)
            if !state.speechModels.ready { modelDownloadBanner.padding(.top, 4) }
        }.padding(4)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(targeted ? accent : .clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard !state.locked, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in state.useAudio(url) } } }
                return true
            }
    }
    private func homeChoice(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(accent)
            Text(L10n.text(title)).font(AppTypography.body.weight(.medium))
            Text(L10n.text(detail)).font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 110).padding(.vertical, 22).padding(.horizontal, 10)
            .background(TalkTuckTheme.quiet, in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var recordingSettingsMenu: some View {
        Picker(L10n.text("音源"), selection: $state.recordingMode) { ForEach(MeetingRecordingMode.allCases) { Text($0.title).tag($0) } }
        Picker(L10n.text("会话类型"), selection: $state.recordingSessionMode) { ForEach(RecordingSessionMode.allCases) { Text($0.title).tag($0) } }
        Picker(L10n.text("转录语言"), selection: $state.language) { ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0.rawValue) } }
        Picker(L10n.text("录音模式"), selection: $state.recordingProfile) { ForEach(RecordingProfile.allCases) { Text($0.title).tag($0) } }
    }
    private var recordingConfigurationSummary: String {
        let language = TranscriptionLanguage(rawValue:state.language)?.title ?? L10n.text("普通话")
        let profile = state.recordingProfile == .realtime ? "实时转录" : state.recordingProfile == .backgroundRealtime ? "后台实时" : "仅录音 · 录完转录"
        return [state.recordingMode.title, language, L10n.text(profile)].joined(separator: " · ")
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TalkTuckAccountToolbarButton: View {
    @ObservedObject var store: TalkTuckAccountStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.text(store.isSignedIn ? "TalkTuck 账号" : "登录 TalkTuck"),
                  systemImage: store.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
        }
        .help(L10n.text(store.isSignedIn ? "TalkTuck 账号" : "登录 TalkTuck"))
        .accessibilityIdentifier("talktuck-account-entry")
    }
}

struct ConnectionsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TalkTuckPageHeader(title: L10n.text("第三方账号"), subtitle: L10n.text("连接钉钉、飞书或 Notion，按需发送选定的转录内容。")) { Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
            TalkTuckSegmentedPicker(items: PersonalDestination.allCases.map { ($0.rawValue, $0) }, selection: $state.syncDestination)
            AccountConnectionPanel(state: state)
            TalkTuckInfo(text: L10n.text(state.syncDestination == .feishu && state.feishuAccount.hasPendingAuthorization ? "已有待处理授权时优先继续，不重复申请。重新申请前需确认旧申请已失效。" : "只在你点击同步后发送选定文字。原始音频保留在本机。"))
            Spacer()
        }.padding(28).frame(width: 720, height: state.syncDestination == .dingtalk ? 530 : 494).font(AppTypography.body).buttonStyle(TalkTuckSecondaryButtonStyle()).controlSize(.extraLarge)
    }
}

struct SyncReviewView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    let close: () -> Void
    @State private var connecting = false
    @State private var showingReceipt = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TalkTuckPageHeader(title: L10n.text("同步这条录音"), subtitle: state.current?.title ?? "") { Button(L10n.text("关闭")) { close() }.disabled(state.syncing).keyboardShortcut(.cancelAction) }
            TalkTuckSegmentedPicker(items: PersonalDestination.allCases.map { ($0.rawValue, $0) }, selection: $state.syncDestination).disabled(state.syncing)
            AccountConnectionPanel(state: state, compact: true)
            SyncContentPreview(state: state)
            if !state.syncStatus.isEmpty {
                HStack(spacing: 16) {
                    Label(L10n.text(state.syncStatus), systemImage: syncNeedsAttention ? "exclamationmark.triangle" : state.remoteURL != nil ? "checkmark" : "info.circle")
                    if let url = state.remoteURL { Link("查看远端结果 ↗", destination: url).buttonStyle(.plain) }
                    Spacer(minLength: 0)
                    if !state.syncReceipt.isEmpty {
                        Button(L10n.text("详情")) { showingReceipt = true }.buttonStyle(.plain).accessibilityLabel(L10n.text("查看 MCP 回执"))
                            .popover(isPresented: $showingReceipt) {
                                ScrollView { Text(state.syncReceipt).font(AppTypography.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }.frame(width: 500, height: 280)
                            }
                    }
                }.font(AppTypography.secondary).foregroundStyle(syncNeedsAttention ? Color.orange : state.remoteURL != nil ? Color.green : TalkTuckTheme.accent)
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background((syncNeedsAttention ? Color.orange : state.remoteURL != nil ? Color.green : TalkTuckTheme.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if let feedback = state.syncFeedback {
                HStack(alignment: .top, spacing: 12) {
                    TalkTuckInfo(text: feedback, warning: state.remoteURL == nil)
                    Button(L10n.text("知道了")) { state.syncFeedback = nil }
                }
            }
            HStack {
                Button(L10n.text("连接账号")) { connecting = true }.disabled(state.syncing)
                Spacer()
                if state.syncing { ProgressView().controlSize(.small) }
                Button(L10n.text(state.syncing ? "同步中…" : "同步到\(state.syncDestination.rawValue)")) { state.syncMeeting() }
                    .buttonStyle(TalkTuckPrimaryButtonStyle(showsProgress: state.syncing)).disabled(state.syncing || !state.canSyncFinalTranscript || !accountReady)
            }
        }.padding(28).frame(width: 720, height: state.syncStatus.isEmpty ? 664 : 736).font(AppTypography.body).buttonStyle(TalkTuckSecondaryButtonStyle()).controlSize(.extraLarge)
        .sheet(isPresented: $connecting) { ConnectionsView(state: state) }

    }
    private var syncNeedsAttention: Bool { ["未完成", "失败", "待核对"].contains { state.syncStatus.contains($0) } }
    private var accountReady: Bool {
        switch state.syncDestination {
        case .dingtalk: return state.dingTalkAccount.connected
        case .notion: return state.notionAccount.connected
        case .feishu: return state.feishuAccount.connected
        }
    }

}

struct SyncTargetStatus: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var store: MCPConnectionStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L10n.text(store.connected ? "已连接" : "尚未连接"), systemImage: store.connected ? "checkmark.circle.fill" : "link")
            Text(L10n.text(store.targetDescription)).font(AppTypography.secondary).foregroundStyle(.secondary)
        }
    }
}
