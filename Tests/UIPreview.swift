import SwiftUI
import AVFoundation
import CryptoKit
@main struct PreviewApp: App {
    @StateObject private var state: AppState
    private let coldState: AppState
    private let optionalModels: OptionalModelStore
    @State private var modelPreview: String?
    @State private var page = 2
    @State private var presented = 0
    private let mini: MiniRecordingController
    private let demoID: UUID
    private let recoveryID: UUID
    private let previewRoot: URL
    private let pages = PreviewPage.load()
    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recordai-ui-preview-" + UUID().uuidString)
        previewRoot = root
        let library = try! MeetingLibrary(root: root)
        let demoID = UUID(); self.demoID = demoID
        let recoveryID = UUID(); self.recoveryID = recoveryID
        if (try? library.list().isEmpty) == true {
            let paragraphs = [
                "大家好，我们开始今天的产品周会。主要讨论三个议题：上周进展、下个迭代的重点，以及用户反馈的处理情况。",
                "我先同步一下设计侧的进展。新版首页的视觉方案已经完成评审，目前正在进行细节设计，预计本周五可以交付给开发。",
                "后端这边，用户体系的重构已经完成 80%，预计下周可以进入测试。另外，我们已经检查了数据迁移的方案。",
                "好的。接下来看看用户反馈的情况，重点关注离线使用和文件管理的体验。"
            ]
            var record = MeetingRecord(id: demoID, title: "产品周会", text: paragraphs.joined(separator: "\n"), duration: 1234, status: .completed)
            record.summary = "本次产品周会同步了设计、开发和用户反馈的进展。团队确认新版首页方案，本周完成交付；下个迭代将重点优化离线使用和文件管理体验。\n\n## 关键要点\n- 新版首页方案已通过评审\n- 用户体系重构完成80%\n- 优先解决离线体验与文件管理问题"
            record.created = Date(timeIntervalSince1970: 1793498400)
            record.isStarred = true
            record.notes = "重点确认：\n• 本周设计交付时间\n• 离线体验验证范围"
            record.actionItems = [MeetingActionItem(title: "完成设计交付", assignee: "设计组", dueDate: Date(timeIntervalSince1970: 1793955600)), MeetingActionItem(title: "验证离线流程", assignee: "测试组", dueDate: Date(timeIntervalSince1970: 1793869200)), MeetingActionItem(title: "整理用户反馈", assignee: "产品组", dueDate: Date(timeIntervalSince1970: 1793696400))]
            record.assistantEntries = [MeetingAssistantEntry(question: "这场会议有哪些后续工作？", answer: "设计组完成首页方案交付；测试组检查离线流程。", isLive: false, citations: [MeetingCitation(id: "1", kind: "final", text: "本周设计方案已经完成评审。")])]
            let directory = library.directory(for: record.id).appendingPathComponent("Audio", isDirectory: true); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = "demo.wav", url = directory.appendingPathComponent("demo.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 19_744_000)!
            buffer.frameLength = 19_744_000
            for i in 0..<Int(buffer.frameLength) {
                // Real sample amplitudes vary at the scale of the displayed waveform bins.
                let bucket = Double(i * 150 / Int(buffer.frameLength))
                let amplitude = 0.03 + abs(sin(bucket * 1.31) * cos(bucket * 0.21)) * 0.32
                buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.12) * amplitude)
            }
            if let writer = try? AVAudioFile(forWriting: url, settings: format.settings) { try? writer.write(from: buffer) }
            record.audioFiles = [file]; record.audioDurations = [file: 1234]
            record.transcriptParagraphs = [TranscriptParagraph(text: paragraphs[0], start: 0, end: 28, audioFile: file, speakerIDs: ["1"], localStart: 0), TranscriptParagraph(text: paragraphs[1], separator: "\n", start: 28, end: 54, audioFile: file, speakerIDs: ["2"], localStart: 28), TranscriptParagraph(text: paragraphs[2], separator: "\n", start: 72, end: 104, audioFile: file, speakerIDs: ["3"], localStart: 72), TranscriptParagraph(text: paragraphs[3], separator: "\n", start: 155, end: 185, audioFile: file, speakerIDs: ["1"], localStart: 155)]
            record.subtitles = "1\n00:00:00,000 --> 00:00:28,000\n" + paragraphs[0] + "\n\n2\n00:00:28,000 --> 00:00:54,000\n" + paragraphs[1] + "\n\n3\n00:01:12,000 --> 00:01:44,000\n" + paragraphs[2] + "\n\n4\n00:02:35,000 --> 00:03:05,000\n" + paragraphs[3] + "\n"
            record.speakerNames = ["1": "发言人 1", "2": "发言人 2", "3": "发言人 3"]; _ = try? library.save(record)
            record.liveUtterances = [LiveUtterance(text: "隔离演示：大家好，我们开始今天的产品周会。", start: 0, end: 5)]
            _ = try? library.save(record)
            let attachment = root.appendingPathComponent("产品需求.txt")
            try? Data("产品周会 · 隔离演示附件".utf8).write(to: attachment)
            _ = try? library.importAttachment(attachment, into: &record)
            for (index, title) in ["用户访谈", "市场策略讨论", "与 Design 团队同步"].enumerated() {
                let other = MeetingRecord(title: title, created: record.created.addingTimeInterval(Double([-68400, -345600, -432000][index])), text: "隔离预览资料", duration: [2880, 3780, 2220][index], status: .completed)
                _ = try? library.save(other)
            }
            let discarded = MeetingRecord(title: "产品方案讨论", created: record.created.addingTimeInterval(-604800), text: "可恢复的演示资料", duration: 2040)
            _ = try? library.save(discarded); try? library.trash(discarded.id)
            let discardedCourse = MeetingRecord(title: "课程录音", created: record.created.addingTimeInterval(-691200), text: "可恢复的隔离演示课程", duration: 2520)
            _ = try? library.save(discardedCourse); try? library.trash(discardedCourse.id)
            let recovery = MeetingRecord(id: recoveryID, title: "待恢复录音", created: record.created.addingTimeInterval(-864000), text: "中断前已保存的文字", status: .interrupted)
            _ = try? library.save(recovery)
            let capture = library.directory(for: recoveryID).appendingPathComponent("Capture/" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
            let mic = capture.appendingPathComponent("microphone.caf")
            buffer.frameLength = 2_112_000
            if let writer = try? AVAudioFile(forWriting: mic, settings: format.settings) { try? writer.write(from: buffer) }
            let system = capture.appendingPathComponent("system.caf")
            if let writer = try? AVAudioFile(forWriting: system, settings: format.settings) { try? writer.write(from: buffer) }
            let tracks = [MeetingAudioTrack(kind: .microphone, url: mic, offset: 0), MeetingAudioTrack(kind: .system, url: system, offset: 0)]
            try? JSONEncoder().encode(tracks).write(to: capture.appendingPathComponent("recording.json"))
        }
        let namespace = "recordai-ui-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: namespace)!
        // Small, hash-correct fixture files exercise the same verified-model presentation.
        // They are never usable for inference; the preview bundle contains no speech engines.
        let modelRoot = root.appendingPathComponent("SpeechModels")
        let bytes = Data("isolated-ui-fixture".utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let files = ["Paraformer", "Qwen3ASR", "Sortformer", "QwenAligner"].map { group in
            ASRModelManifest.File(path: group + "/preview.bin", bytes: Int64(bytes.count), sha256: sha,
                url: URL(string: "https://modelscope.cn/preview")!, overseasURL: URL(string: "https://huggingface.co/preview")!)
        }
        let manifest = ASRModelManifest(version: 1, files: files)
        for file in files {
            let destination = modelRoot.appendingPathComponent(file.path)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: destination)
        }
        try? manifest.saveReceipt(at: modelRoot)
        let modelStore = ASRModelStore(root: modelRoot, manifest: manifest)
        let accountStub = root.appendingPathComponent("preview-account")
        let stub = """
        #!/bin/sh
        if [ "$1" = "profile" ]; then
          echo '{"profiles":[{"profile":"preview","userName":"演示账号","corpName":"隔离预览","status":"active","isCurrent":true}]}'
        elif [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          echo '{"authenticated":true,"token_valid":true}'
        else
          echo '{"ok":false,"message":"隔离预览不会连接或写入外部服务"}'
        fi
        """
        try? Data(stub.utf8).write(to: accountStub)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accountStub.path)
        let feishuStub = root.appendingPathComponent("preview-feishu-account")
        let feishuScript = """
        #!/bin/sh
        if [ "$4" = "status" ]; then
          echo '{"appId":"isolated-preview-app","identities":{"user":{"available":false}}}'
        else
          echo '{"ok":false,"error":{"type":"network","message":"隔离预览不会打开授权或连接外部服务"}}'
          exit 1
        fi
        """
        try? Data(feishuScript.utf8).write(to: feishuStub)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: feishuStub.path)
        defaults.set(true, forKey: "personalDingTalk.detached")
        optionalModels = OptionalModelStore(root: root.appendingPathComponent("AssistantModels"), defaults: defaults)
        let notionStore = MCPConnectionStore(namespace: namespace + "notion")
        let previewState = AppState(storageURL: root, connectionNamespace: namespace,
            speechModelStore: modelStore,
            dingTalkConnection: DingTalkAccountConnection(defaults: defaults, executable: accountStub),
            feishuConnection: FeishuAccountConnection(executable: feishuStub, pendingAccount: namespace,
                pendingCredentialReader: { MCPCredential(accessToken: "isolated-preview-device-code", expiresAt: Date().addingTimeInterval(600)) }),
            notionConnection: NotionAccountConnection(store: notionStore, defaults: defaults, metadataNamespace: namespace))
        previewState.select(demoID)
        previewState.playbackVolume = 0
        mini = MiniRecordingController(state: previewState, defaults: defaults)
        coldState = AppState(storageURL: root.appendingPathComponent("FirstUse"), connectionNamespace: namespace + "cold",
            speechModelStore: ASRModelStore(root: root.appendingPathComponent("FirstUseModels")),
            dingTalkConnection: DingTalkAccountConnection(defaults: defaults, executable: nil),
            feishuConnection: FeishuAccountConnection(executable: nil, pendingAccount: namespace + "cold"),
            notionConnection: NotionAccountConnection(store: MCPConnectionStore(namespace: namespace + "coldNotion"), defaults: defaults, metadataNamespace: namespace + "cold"))
        _state = StateObject(wrappedValue: previewState)
    }
    var body: some Scene {
        WindowGroup("RecordAI") {
            MainView(state: page == 1 ? coldState : state, initialFilter: page == 3 ? "星标" : page == 5 ? "回收站" : "全部")
                .id(page).background(RecordingWindowObserver(state: page == 1 ? coldState : state).frame(width: 0, height: 0)).frame(minWidth: 1040, minHeight: 760).font(AppTypography.body).controlSize(.extraLarge)
                .preferredColorScheme(page == 40 ? .dark : .light)
                .sheet(isPresented: Binding(get: { presented != 0 }, set: { if !$0 { presented = 0 } })) { previewSheet.id(presented) }
        }.defaultSize(width: 1440, height: 900).commands {
            CommandMenu("逐页验收") {
                Button("检查窗口布局…") { inspectLayout() }
                Divider()
                ForEach(Array(Set(pages.map(\.group))).sorted(), id: \.self) { group in
                    Menu(group) { ForEach(pages.filter { $0.group == group }) { item in Button(item.id + " · " + item.title) { show(item.number) } } }
                }
            }
        }
        MenuBarExtra("录音预览", systemImage: "waveform") { RecordingMenuBarView(state: state) }
        Settings { RecordingAppConfigurationView(state: state, optionalModels: optionalModels).preferredColorScheme(page == 40 ? .dark : .light) }
    }

    /// Preview-only geometry evidence; never included in the shipping app.
    private func inspectLayout() {
        guard let window = state.mainWindow else { return }
        var lines = ["page=\(page)", "window=\(window.frame)", "contentLayout=\(window.contentLayoutRect)",
                     "minimum=\(window.minSize) contentMinimum=\(window.contentMinSize)",
                     "screen=\(String(describing: window.screen?.visibleFrame))"]
        func visit(_ view: NSView, depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) fitting=\(view.fittingSize)")
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        if let root = window.contentView { visit(root, depth: 0) }
        let url = previewRoot.appendingPathComponent("window-layout.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let alert = NSAlert()
        alert.messageText = "窗口布局诊断"
        alert.informativeText = lines.prefix(5).joined(separator: "\n") + "\n\n" + url.path
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }

    @ViewBuilder private var previewSheet: some View {
        switch presented {
        case 15...17:
            VStack(alignment: .leading, spacing: 20) {
                ASRModelDownloadPanel(ready: false, busy: modelPreview == "progress", progress: 0.62,
                    status: "正在下载并校验本地模型文件…", error: modelPreview == "error" ? "网络连接已中断。" : nil,
                    totalBytes: (try? ASRModelManifest.load())?.totalBytes,
                    download: { modelPreview = "progress" }, cancel: { modelPreview = "initial" }, close: { presented = 0 })
            }.padding(28).frame(width: 720).buttonStyle(RecordAISecondaryButtonStyle())
        case 20...23: ConnectionsView(state: state)
        case 18...19, 24:
            RecordingAppConfigurationView(state: state, optionalModels: optionalModels,
                initialSection: presented == 18 ? "recording" : presented == 19 ? "models" : presented == 24 ? "data" : "accounts")
        case 25: RecordingDeliveryView(state: state)
        case 26...28: SyncReviewView(state: state) { presented = 0 }
        case 29...30: CaptureRecoveryView(state: state)
        case 31: RecordAIExecutionView(state: state)
        case 32:
            if let paragraph = state.current?.transcriptParagraphs.first {
                TranscriptParagraphEditor(paragraph: paragraph, speakerName: state.current?.paragraphSpeaker(paragraph) ?? "", cancel: { presented = 0 }) { text in
                    let success = state.editTranscriptParagraph(paragraph.id, text: text)
                    if success { presented = 0 }; return success
                }
            }
        case 33:
            if let record = state.current {
                SpeakerEditor(record: record, speakerID: "2", cancel: { presented = 0 }) { name, target in
                    let success = state.renameSpeaker("2", name: name, mergeInto: target)
                    if success { presented = 0 }; return success
                }
            }
        case 34:
            MeetingActionEditor(item: state.current?.actionItems.first ?? MeetingActionItem(title: ""), cancel: { presented = 0 }) { item in
                let success = state.updateActionItems { items in
                    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
                }
                if success { presented = 0 }; return success
            }
        case 37...38: MeetingWorkspaceView(state: state, initialTab: presented == 37 ? "我的笔记" : "对话", close: { presented = 0 }).padding(28).frame(width: 720)
        case 36: QuitConfirmationView(activity: .recording, cancel: { presented = 0 }, confirm: { presented = 0 })
        default: EmptyView()
        }
    }
    private func show(_ number: Int) {
        // State fixtures are isolated; no microphone, model inference or external writes run here.
        mini.hide(); state.recording = false; state.paused = false; state.busy = false
        state.syncing = false; state.syncStatus = ""; state.syncReceipt = ""; state.remoteURL = nil; state.recordingIssue = nil; state.error = nil; state.search = ""
        state.deletionRequest = nil; state.showModelDownload = false; state.showSettings = false; state.showExecutionTrace = false
        presented = 0; state.showRecordingWindow(); state.select(demoID); page = number
        state.status = "准备就绪 · 音频仅在这台 Mac 上处理"
        state.transcriptPhase = .idle; state.liveText = ""; state.livePartial = ""
        state.expandedRealtime = false; state.editingTranscript = false
        state.elapsed = 0; state.level = 0; state.liveLevels = []
        state.seek([2, 3, 39, 40].contains(number) ? 496 : 0)
        if let window = state.mainWindow {
            // The reference dimensions include window chrome. setContentSize adds the
            // toolbar height and can put the last navigation row outside the display.
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: number == 39 ? 1040 : 1440, height: 900)), display: true)
        }
        if number == 1 {
            try? FileManager.default.removeItem(at: state.speechModels.root.appendingPathComponent(".verified"))
        } else { try? state.speechModels.manifest?.saveReceipt(at: state.speechModels.root) }
        state.speechModels.refresh()
        switch number {
        case 1: state.select(nil)
        case 4: state.search = "未匹配的搜索词"
        case 5: state.select(nil)
        case 6...8, 10, 12...14, 43:
            state.recordingProfile = number == 8 ? .backgroundRealtime : .realtime
            state.prepareRecordingProfile(); state.recording = true; state.elapsed = 122
            state.level = 0.28; state.liveLevels = (0..<72).map { Float(abs(sin(Double($0) * 0.4)) * 0.4) }
            state.liveText = "这是隔离演示资料，用于核对实时转写。"
            state.livePartial = "预计本周五完成设计交付。"
            state.paused = [7, 10, 13, 14].contains(number)
            if number == 10 || number == 14 { state.recordingIssue = "麦克风已断开，请重新连接后继续。" }
            if (12...14).contains(number) { state.showMiniRecorder() }
        case 9: state.error = "没有可用的麦克风输入设备"
        case 11: state.busy = true; state.transcriptPhase = .diarizing; state.status = "正在区分发言人…"
        case 15...17: modelPreview = number == 16 ? "progress" : number == 17 ? "error" : "initial"; presented = number
        case 18...24:
            state.syncDestination = number == 21 ? .feishu : number == 22 ? .notion : .dingtalk
            if number == 20 { state.dingTalkAccount.disconnect() }
            if number == 23 { Task { await state.dingTalkAccount.connect() } }
            presented = number
        case 25...34:
            if (26...28).contains(number) { Task { await state.dingTalkAccount.connect() } }
            if number == 27 { state.syncing = true; state.syncStatus = "正在保存文档 · 请勿重复提交。" }
            if number == 28 { state.syncStatus = "演示：同步完成"; state.remoteURL = URL(string: "https://example.invalid/recordai-demo"); state.syncReceipt = "这是隔离预览回执，没有发送外部文档。" }
            if number == 29 { state.select(recoveryID) }
            if number == 31 {
                state.busy = true; state.transcriptPhase = .recognizing
                state.status = "正在生成最终转录"; state.elapsed = 1234
            }
            presented = number
        case 35: state.deleteCurrent()
        case 36:
            state.recording = true; state.elapsed = 122
            Task { @MainActor in _ = state.prepareToQuit() }
        case 37...38: presented = number
        case 41: state.chooseAudio()
        case 42: state.export(kind: "Markdown")
        case 44:
            state.reportRecoverableError("网络连接暂时不可用。已有资料保留，请返回后重试。") { [weak state] in
                state?.status = "已重试隔离演示任务（未连接外部服务）"
            }
        default: break
        }
    }
}

private struct PreviewPage: Decodable, Identifiable {
    let id: String
    let title: String
    let group: String
    var number: Int { Int(id.prefix(2)) ?? 0 }
    static func load() -> [Self] {
        struct Manifest: Decodable { let pages: [PreviewPage] }
        guard let url = Bundle.main.url(forResource: "UIPages", withExtension: "json"), let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return manifest.pages
    }
}
