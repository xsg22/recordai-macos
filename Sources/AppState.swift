import AppKit
import Combine
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

typealias Transcript = MeetingRecord

enum PersonalDestination: String, CaseIterable, Identifiable {
    case dingtalk = "钉钉", feishu = "飞书", notion = "Notion"
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @Published var history: [MeetingRecord] = []
    @Published private(set) var trashedHistory: [MeetingRecord] = []
    @Published var deletionRequest: MeetingRecord?
    @Published var selection: UUID?
    @Published var text = ""
    @Published var title = ""
    @Published var search = ""
    @Published private(set) var organization = LibraryOrganization()
    @Published private(set) var organizationIssue: String?
    @Published var groupFilter = ""
    @Published var editingTranscript = false
    @Published var audio: URL?
    @Published var playbackSegment = 0
    @Published var language = TranscriptionLanguage.saved {
        didSet {
            guard TranscriptionLanguage(rawValue: language) != nil else { language = oldValue; return }
            UserDefaults.standard.set(language, forKey: TranscriptionLanguage.preferenceKey)
        }
    }
    @Published var busy = false
    @Published var recording = false
    @Published var preparing = false
    @Published private(set) var quitting = false
    private var quitPromptVisible = false
    @Published var paused = false
    @Published var recordingMode: MeetingRecordingMode = .microphone
    @Published private(set) var activeRecordingSources = RecordingSources(mode: .microphone)
    @Published private(set) var switchingRecordingSource: MeetingAudioTrack.Kind?
    @Published var miniShowsCaptions = true {
        didSet { if miniShowsCaptions { flushLivePresentation() } }
    }
    var recordingIsMuted: Bool { recording && activeRecordingSources.isMuted }
    var miniTranscriptPreview: MiniTranscriptPreview { MiniTranscriptPreview(text: liveText, partial: livePartial) }
    @Published var level: Float = 0
    @Published var liveLevels = [Float](repeating: 0, count: 72)
    @Published var recordingIssue: String?
    @Published private(set) var recoveryBusy = false
    @Published private(set) var recoveryCandidates: [CaptureRecoveryCandidate] = []
    @Published private(set) var recoveryWarnings: [String] = []
    @Published private(set) var recoveryStatus = ""
    private var recoveryTask: Task<Void, Never>?
    @Published var status = "准备就绪 · 本地转录"
    @Published var error: String? { didSet { errorRetry = nil } }
    @Published private(set) var errorRetry: (() -> Void)?
    private var errorMeetingID: UUID?
    @Published var elapsed = 0
    @Published var playing = false
    @Published private(set) var playingParagraphID: UUID?
    private var paragraphPlaybackEnd: Double?
    /// 测试可静音驱动真实播放器，生产默认原音量。
    var playbackVolume: Float = 1
    @Published var playbackTime: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var showSettings = false
    @Published var showExecutionTrace = false
    @Published var showModelDownload = false
    @Published private(set) var agentOnboardingRecordingID: UUID?
    @Published private(set) var agentSetupIssue: String?
    private let agentOnboarding: AgentOnboarding
    let speechModels: ASRModelStore
    let hotwords: PersonalHotwords
    let hotwordSync: HotwordSync
    @Published var syncDestination: PersonalDestination = .dingtalk
    @Published var syncing = false
    @Published var syncStatus = ""
    @Published var syncReceipt = ""
    @Published var syncFeedback: String?
    @Published var remoteURL: URL?
    @Published var recordingProfile: RecordingProfile = .realtime
    @Published var recordingSessionMode: RecordingSessionMode = .conference
    @Published private(set) var activeRecordingSessionMode: RecordingSessionMode = .conference
    @Published private(set) var continuousSegments: [ContinuousSegmentInfo] = []
    @Published private(set) var activeRecordingProfile: RecordingProfile = .realtime
    @Published var mainWindowVisible = true {
        didSet { if mainWindowVisible && !oldValue { flushLivePresentation() } }
    }
    @Published var expandedRealtime = false {
        didSet { if expandedRealtime && !oldValue { flushLivePresentation() } }
    }
    weak var mainWindow: NSWindow?
    var openRecordingWindow: (() -> Void)?
    weak var miniController: MiniRecordingController?
    @Published private(set) var miniMode = false
    @Published private(set) var miniWindowVisible = false
    @Published private(set) var inlineRecorderVisible = false
    @Published private(set) var recordingNavigationRevision = 0
    @Published private(set) var miniSessionID: UUID?
    var compactRecordingUI: Bool { recording && activeRecordingProfile.compact(windowVisible: mainWindowVisible, expanded: expandedRealtime) }
    private var pendingLivePresentation: (text: String, partial: String)?
    private var lastLivePresentation = Date.distantPast
    private var lastLiveSave = Date.distantPast
    @Published var liveEnabled = true
    @Published var liveText = ""
    @Published var livePartial = ""
    @Published var transcriptPhase: TranscriptPhase = .idle
    private var transcriptionGeneration: UUID?
    private var recordingBaseDuration: Double = 0
    private var liveSegmentOffset: Double = 0
    @Published var liveStatus = ""
    let dingTalkAccount: DingTalkAccountConnection
    let notionAccount: NotionAccountConnection
    let feishuAccount: FeishuAccountConnection
    let cloudAccount: TalkTuckAccountStore
    @Published private(set) var librarySync: LibrarySyncEngine?
    @Published private(set) var libraryAudioSync: LibraryAudioSyncEngine?
    let dingTalk: MCPConnectionStore
    let feishu: MCPConnectionStore
    let notion: MCPConnectionStore
    private let captureStarter: @MainActor (MeetingRecorder, MeetingCaptureRequest) async throws -> Void
    private let recorder: MeetingRecorder
    private var continuousSegmenter: ContinuousRecordingSegmenter?
    private var continuousWorker: Task<Void, Never>?
    private var continuousWorkerEngine: TranscriptionEngine?
    private var continuousMeetingID: UUID?
    @Published private(set) var continuousProcessingCount = 0
    var continuousProcessing: Bool { continuousWorker != nil }
    var continuousQueuedCount: Int { continuousSegments.filter { $0.status == "queued" }.count }
    var continuousFailedCount: Int { continuousSegments.filter { $0.status == "failed" }.count }
    private var timer: Timer?
    private var playbackTimer: Timer?
    private var player: MeetingAudioPlayer?
    private let playbackFactory: @MainActor (URL) throws -> MeetingAudioPlayer
    private var task: Task<Void, Never>?
    private var engine: TranscriptionEngine?
    @Published private(set) var recordingID: UUID?
    @Published private(set) var transcriptionRecordingID: UUID?
    private var library: MeetingLibrary?
    private var autosave: Task<Void, Never>?
    private var accountSubscriptions = Set<AnyCancellable>()
    private var talkTuckControlTimer: Timer?
    private var liveSession: LiveTranscriptionSession?
    private var liveGeneration: UUID?
    private var liveCommitted: [LiveUtterance] = []
    private var livePendingRefinement: [LiveUtterance] = []
    private var liveCurrentPartial = ""
    private var liveHasRefinement = false
    private var liveRefiner: LivePreviewRefiner?
    private var livePrefix = ""
    private let storage: URL
    var model: URL? { speechModels.ready ? ASRResources.qwen : nil }

    var activeRecordingID: UUID? { recordingID ?? (recording ? miniSessionID ?? selection : nil) }
    var recordingRecord: MeetingRecord? { history.first { $0.id == activeRecordingID } }
    var isViewingRecording: Bool { recording && selection == activeRecordingID }
    var isViewingActiveTask: Bool { selection == (recordingID ?? transcriptionRecordingID ?? (continuousProcessing ? continuousMeetingID : nil) ?? selection) }
    var canBrowseRecordings: Bool { !preparing && !recoveryBusy && !quitting }
    var canPlayCurrentRecording: Bool { !preparing && !isViewingRecording && audio != nil }
    var showsInlineRecorder: Bool { recording && !isViewingRecording && !miniMode }
    var displayedLiveText: String { recording && !isViewingRecording ? current?.previewText ?? "" : liveText }
    var displayedLivePartial: String { recording && !isViewingRecording ? "" : livePartial }
    var recordingLiveUtterances: [LiveUtterance] { (recordingRecord?.liveUtterances ?? []).filter { $0.start >= liveSegmentOffset - 0.001 } }
    var current: MeetingRecord? { history.first { $0.id == selection } }
    var syncStore: MCPConnectionStore {
        switch syncDestination { case .dingtalk: return dingTalk; case .feishu: return feishu; case .notion: return notion }
    }
    var filteredHistory: [MeetingRecord] {
        history.filter { record in
            let group = organization.group(record.groupID)
            guard groupFilter.isEmpty || (groupFilter == "ungrouped" ? group == nil : group?.id.uuidString == groupFilter) else { return false }
            let searchable = [record.title, record.text, group?.name ?? ""]
            return search.isEmpty || searchable.joined(separator: "\n").localizedStandardContains(search)
        }
    }
    var locked: Bool { busy || recording || preparing || quitting || recoveryBusy || continuousWorker != nil }
    var canRetryMicrophone: Bool { recording && paused && recorder.canRetryMicrophone }
    var canSyncFinalTranscript: Bool {
        !locked && !syncing && current?.status == .completed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var markdown: String {
        guard var current else { return "" }
        let editedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !editedTitle.isEmpty { current.title = editedTitle }
        current.text = text
        return AgentDataPublisher.presentationMarkdown(current)
    }

    init(storageURL: URL? = nil, connectionNamespace: String = "", speechModelStore: ASRModelStore? = nil,
         dingTalkConnection: DingTalkAccountConnection? = nil, feishuConnection: FeishuAccountConnection? = nil,
         notionConnection: NotionAccountConnection? = nil, recorder: MeetingRecorder? = nil,
         cloudAccount: TalkTuckAccountStore? = nil,
         captureStarter: @escaping @MainActor (MeetingRecorder, MeetingCaptureRequest) async throws -> Void = { recorder, request in
             try await recorder.start(mode: request.mode, directory: request.directory, sessionMode: request.sessionMode,
                 meetingOffset: request.meetingOffset, segmenter: request.segmenter)
         },
         playbackFactory: @escaping @MainActor (URL) throws -> MeetingAudioPlayer = { try MeetingAudioPlayer(contentsOf: $0) }) {
        self.captureStarter = captureStarter
        self.playbackFactory = playbackFactory
        self.cloudAccount = cloudAccount ?? TalkTuckAccountStore()
        self.recorder = recorder ?? MeetingRecorder()
        storage = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoHearTranscribe", isDirectory: true)
        let personalHotwords = PersonalHotwords(root: storage)
        hotwords = personalHotwords
        hotwordSync = HotwordSync(hotwords: personalHotwords)
        agentOnboarding = AgentOnboarding(storage: storage)
        speechModels = speechModelStore ?? ASRModelStore()
        dingTalk = MCPConnectionStore(namespace: connectionNamespace + "dingtalk")
        feishu = MCPConnectionStore(namespace: connectionNamespace + "feishu")
        notion = MCPConnectionStore(namespace: connectionNamespace + "notion")
        dingTalkAccount = dingTalkConnection ?? DingTalkAccountConnection()
        notionAccount = notionConnection ?? NotionAccountConnection(store: notion)
        feishuAccount = feishuConnection ?? FeishuAccountConnection()
        speechModels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &accountSubscriptions)
        hotwords.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &accountSubscriptions)
        hotwordSync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &accountSubscriptions)
        dingTalkAccount.onProgress = { [weak self] message in
            self?.syncStatus = message
            self?.status = message
        }
        for changes in [dingTalkAccount.objectWillChange, notionAccount.objectWillChange, feishuAccount.objectWillChange] {
            changes.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &accountSubscriptions)
        }
        if dingTalk.configuration.name == "个人工作区" { dingTalk.configuration.name = "个人钉钉" }
        if feishu.configuration.name == "个人工作区" { feishu.configuration.name = "个人飞书" }
        if notion.configuration.name == "个人工作区" { notion.configuration.name = "个人 Notion" }
        do {
            library = try MeetingLibrary(root: storage, publishAgentDataOnInit: storageURL != nil && cloudAccount == nil)
            organization = try library?.organization() ?? LibraryOrganization()
            history = try library?.list() ?? []
            agentOnboardingRecordingID = history.first(where: { agentOnboarding.eligible($0) })?.id
            trashedHistory = try library?.listTrashed() ?? []
            if let warnings = library?.warnings, !warnings.isEmpty { error = warnings.joined(separator: "\n") }
        } catch { self.error = "读取录音资料库失败：\(error.localizedDescription)" }
        self.recorder.onUpdate = { [weak self] seconds, level in
            guard let self else { return }
            if self.elapsed != Int(seconds) { self.elapsed = Int(seconds) }
            guard !self.compactRecordingUI || self.miniWindowVisible else { return }
            self.level = level
            if self.recording && !self.paused { self.liveLevels.append(level); self.liveLevels = Array(self.liveLevels.suffix(72)) }
        }
        self.recorder.onError = { [weak self] error in
            self?.paused = true; self?.recordingIssue = error.localizedDescription
            self?.status = "录音已暂停。请处理提示后重试，或停止并保存。"
        }
        let controlTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processTalkTuckCommands(); self?.publishRecordingStatus() }
        }
        talkTuckControlTimer = controlTimer
        RunLoop.main.add(controlTimer, forMode: .common)
        configureLibrarySync()
        publishRecordingStatus()
        // Isolated previews/tests must opt in by injecting their own account store;
        // never attach the user's real credentials to an arbitrary fixture library.
        if storageURL == nil || cloudAccount != nil { startAccountRestoration() }
    }

    private var accountRestorationTask: Task<Void, Never>?

    /// Application services must run even when SwiftUI has not presented a window.
    func startAccountRestoration() {
        guard accountRestorationTask == nil else { return }
        accountRestorationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let retry = await self?.restoreStartupAccount(), retry else { return }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
            }
        }
    }

    private func restoreStartupAccount() async -> Bool {
        await cloudAccount.restore()
        let retry = cloudAccount.needsRestoreRetry || cloudAccount.busy
        if !retry { library?.finishAgentStartup(userId: cloudAccount.userId) }
        return retry
    }

    deinit { accountRestorationTask?.cancel() }

    private func configureLibrarySync() {
        guard let library else { return }
        let adapter = MacLibrarySyncAdapter(library:library)
        adapter.beforeRead = { [weak self] in if self?.saveEdits() == false { throw LibrarySyncError.unavailable } }
        let sync = LibrarySyncEngine(root:storage.appendingPathComponent("Sync"),adapter:adapter)
        librarySync = sync
        let audio = LibraryAudioSyncEngine(root:storage.appendingPathComponent("Sync"),adapter:MacLibraryAudioAdapter(library:library))
        libraryAudioSync = audio
        sync.onEnabledChange = { [weak audio] enabled in audio?.setAutomaticEnabled(enabled) }
        sync.onSynchronized = { [weak audio] ids in Task { await audio?.synchronizeAutomatically(recordingIds:ids) } }
        audio.onInstalled = { [weak self] in self?.reloadSyncProjection();if let self { self.selectPlaybackSegment(max(0,(self.current?.audioFiles.count ?? 1)-1)) } }
        library.didChange = { [weak sync] in Task { @MainActor in sync?.localDidChange() } }
        sync.onProjection = { [weak self] in self?.reloadSyncProjection() }
        cloudAccount.onSessionChange = { [weak self, weak sync] in
            guard let self else { return }
            self.hotwordSync.connect(self.cloudAccount.syncAccess)
            guard let sync else { return }
            library.updatingAccount(self.cloudAccount.userId) {
                _ = self.saveEdits(); audio.disconnect(); sync.disconnect()
                if let access = self.cloudAccount.syncAccess {
                    do {
                        if let previous = self.cloudAccount.previousServer {
                            try ServiceNamespaceMigration.run(root:self.storage.appendingPathComponent("Sync"),userId:access.userId,from:previous,to:access.server)
                        }
                        try sync.connect(userId:access.userId,server:access.server,transport:LibrarySyncHTTP(server:access.server,token:access.token))
                        try audio.connect(userId:access.userId,server:access.server,transport:LibraryAudioHTTP(server:access.server,token:access.token))
                        audio.setAutomaticEnabled(sync.enabled)
                        try self.cloudAccount.completeServerMigration()
                    }
                    catch { audio.disconnect(); sync.disconnect(); self.error = "本机同步状态无法读取，已暂停同步。" }
                }
            }
            self.reloadSyncProjection()
        }
    }
    func reloadSyncProjection() {
        guard let library else { return }
        let editorWasClean = current.map { title == $0.title && text == $0.text } ?? true
        do {
            organization = try library.organization(); history = try library.list(); trashedHistory = try library.listTrashed()
            if !groupFilter.isEmpty, !organization.groups.contains(where: { $0.id.uuidString == groupFilter }) { groupFilter = "" }
            if let selection, !history.contains(where: { $0.id == selection }) { self.selection = nil; text = ""; title = ""; stopPlayback() }
            else if editorWasClean, let current { title = current.title;text = current.text }
        } catch { self.error = "读取录音资料库失败：\(error.localizedDescription)" }
    }

    private func publishRecordingStatus() {
        let snapshot = TalkTuckRuntimeStatus(recording: recording, paused: paused, preparing: preparing, busy: busy,
            recordingID: recordingID ?? selection, status: status, issue: recordingIssue)
        guard let data = try? AgentCodec.encoder().encode(snapshot) else { return }
        let url = agentDataURL.appendingPathComponent("runtime.json")
        guard (try? TalkTuckControlQueue.requireContained(url, root: agentDataURL)) != nil else { return }
        try? data.write(to: url, options: .atomic)
    }

    func processTalkTuckCommands() {
        for (url, command) in TalkTuckControlQueue.pending(root: storage.appendingPathComponent("AgentData")) {
            var result = ""
            var accepted = true
            if Date().timeIntervalSince(command.createdAt) > 30 || command.createdAt.timeIntervalSinceNow > 5 {
                TalkTuckControlQueue.finish(url, root: agentDataURL, result: "命令已过期，请查询状态后重新发起。", accepted: false)
                continue
            }
            if preparing || busy || recoveryBusy || quitting || syncing ||
                (continuousProcessing && !recording && ["start_recording", "retry_transcription"].contains(command.action)) {
                TalkTuckControlQueue.finish(url, root: agentDataURL, result: "当前任务忙碌，请稍后重试。", accepted: false)
                continue
            }
            switch command.action {
            case "start_recording":
                if !recording {
                    toggleRecording(); accepted = preparing || recording
                    result = accepted ? "录音启动请求已接受，请查询实际状态" : error ?? (showModelDownload ? "请先完成语音模型下载。" : "录音未能开始。")
                } else { result = "已经在录音" }
            case "stop_recording":
                if recording { toggleRecording(); result = "录音停止请求已接受" } else { result = "当前没有录音" }
            case "pause_recording":
                if recording && !paused { pauseRecording(); result = "录音暂停请求已接受" } else { result = paused ? "已经暂停" : "当前没有录音" }
            case "resume_recording":
                if recording && paused { pauseRecording(); result = "录音继续请求已接受" } else { result = "当前不需要继续录音" }
            case "retry_transcription":
                if let current, !recording, current.audioFiles.isEmpty == false { transcribe(recordingID:current.id); result = "转录重试请求已接受" } else { result = "当前没有可重试音频" }
            default: result = "未识别控制动作"; accepted = false
            }
            TalkTuckControlQueue.finish(url, root: storage.appendingPathComponent("AgentData"), result: result, accepted: accepted)
        }
    }

    private func update(_ record: MeetingRecord) throws {
        guard let library else { throw TranscriptionError.message("本地录音资料库不可用。") }
        let saved = try library.save(record)
        publishStoredRecord(saved)
    }

    private func publishStoredRecord(_ saved: MeetingRecord) {
        if let index = history.firstIndex(where: { $0.id == saved.id }) { history[index] = saved }
        else { history.insert(saved, at: 0) }
        if !agentOnboarding.seen && ((saved.id == selection && agentOnboarding.eligible(saved)) ||
            !history.contains(where: { $0.id == agentOnboardingRecordingID && agentOnboarding.eligible($0) })) {
            agentOnboardingRecordingID = agentOnboarding.eligible(saved) ? saved.id : nil
        }
    }

    func toggleStar(recordingID: UUID? = nil) {
        guard !locked, let id = recordingID ?? selection else { return }
        guard saveEdits() else { return }
        guard var record = history.first(where: { $0.id == id }) else { return }
        record.isStarred.toggle()
        do { try update(record) } catch { self.error = "保存星标失败：\(error.localizedDescription)" }
    }

    func chooseAttachment() {
        guard !locked, current != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "附件会保存本地副本，不会随转录自动发送。"
        if panel.runModal() == .OK, let url = panel.url { addAttachment(url) }
    }

    @discardableResult func addAttachment(_ url: URL) -> Bool {
        guard !locked, let library, saveEdits(), var record = current else { return false }
        do {
            _ = try library.importAttachment(url, into: &record)
            publishStoredRecord(record); return true
        } catch { self.error = "添加附件失败：\(error.localizedDescription)"; return false }
    }

    func openAttachment(_ attachment: MeetingAttachment, reveal: Bool = false) {
        guard let record = current, let stored = record.attachments.first(where: { $0.id == attachment.id }), let library else { return }
        do {
            let url = try library.attachmentURL(stored, meeting: record.id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MeetingLibraryError.missingAttachment }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else if !NSWorkspace.shared.open(url) { self.error = "未找到可以打开此附件的应用，请在 Finder 中查看。" }
        } catch { self.error = "无法打开附件：\(error.localizedDescription)" }
    }

    @discardableResult func removeAttachment(_ id: UUID) -> Bool {
        guard !locked, let library, saveEdits(), var record = current else { return false }
        do { try library.removeAttachment(id, from: &record); publishStoredRecord(record); return true }
        catch { self.error = "移除附件失败：\(error.localizedDescription)"; return false }
    }

    func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000); try Task.checkCancellation(); self?.saveEdits() } catch { }
        }
    }

    @discardableResult func saveEdits() -> Bool {
        autosave?.cancel(); autosave = nil
        guard var current else { return true }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTitle = cleanTitle.isEmpty ? current.title : cleanTitle
        guard current.title != savedTitle || current.text != text else { return true }
        current.title = savedTitle; current.text = text
        do { try update(current); return true } catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }

    func select(_ id: UUID?, saveCurrent: Bool = true) {
        if saveCurrent && !saveEdits() { return }
        stopPlayback()
        selection = id
        if let current, agentOnboarding.eligible(current) { agentOnboardingRecordingID = current.id }
        title = current?.title ?? ""; text = current?.text ?? ""
        // While capturing, liveText/livePartial belong to the session, not the
        // browsing selection. Historic previews are projected independently.
        if !recording { liveText = current?.previewText ?? ""; livePartial = "" }
        if !busy && !recording { transcriptPhase = current?.status == .completed ? .completed : .idle }
        if !liveText.isEmpty && !recording { liveStatus = "录音时实时结果 · 未定稿，仅供回顾" }
        playbackSegment = max(0, (current?.audioFiles.count ?? 1) - 1)
        selectPlaybackSegment(playbackSegment)
        if !recording && !busy, let message = current?.recoveryMessage { status = message }
    }

    func bindRecordingContext(to id: UUID) {
        recordingID = id; miniSessionID = id
        if recorder.state == .recording || recorder.state == .paused { activeRecordingSources = recorder.activeSources }
    }

    func returnToRecording() {
        guard let id = activeRecordingID else { showRecordingWindow(); return }
        search = ""; groupFilter = ""
        select(id)
        recordingNavigationRevision += 1
        showRecordingWindow()
    }

    func chooseAudio() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("导入音频后会在本机保存副本；登录并开启同步时，原音会自动上传。")
        if panel.runModal() == .OK, let url = panel.url { useAudio(url) }
    }

    func reportRecoverableError(_ message: String, retry: @escaping () -> Void) {
        error = message
        errorMeetingID = selection
        errorRetry = retry
    }

    func retryLastError() {
        guard let retry = errorRetry else { return }
        guard selection == errorMeetingID else { error = "当前录音已改变，请返回原录音后重试。"; return }
        guard !locked && !syncing else { error = "已有任务正在进行，请等待完成后再重试。"; return }
        error = nil
        retry()
    }

    func useAudio(_ url: URL) {
        guard !locked, let library, saveEdits() else { return }
        do {
            var record = MeetingRecord(title: url.deletingPathExtension().lastPathComponent, language: language, status: .recorded)
            record.source = .imported
            _ = try library.importAudio(url, into: &record)
            try update(record)
            select(record.id)
            status = "音频已保存在录音资料库，可以开始转录"
            let id = record.id
            Task {
                if let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds.isFinite {
                    if var latest = history.first(where: { $0.id == id }) {
                        latest.duration = duration.seconds
                        do { try update(latest); if selection == id { playbackDuration = duration.seconds } }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        } catch { reportRecoverableError("导入失败：\(error.localizedDescription)") { [weak self] in self?.useAudio(url) } }
    }

    func transcribe(recordingID targetID: UUID? = nil) {
        speechModels.refresh()
        guard model != nil else { showModelDownload = true; return }
        let target = targetID.flatMap { id in history.first { $0.id == id } } ?? (targetID == nil ? current : nil)
        guard let model, !locked, var record = target, let library else { return }
        if record.recordingSessionMode == .continuous {
            retryContinuousSegments(record)
            return
        }
        guard let executable = ASRResources.executable("qwen-asr") else {
            error = "安装包缺少转录引擎。"; return
        }
        guard saveEdits() else { return }
        if selection == record.id { stopPlayback() }
        record = history.first(where: { $0.id == record.id }) ?? record
        let id = record.id
        let appending = !record.pendingAudioFiles.isEmpty
        let files = appending ? record.pendingAudioFiles : record.audioFiles
        let urls: [URL]
        do {
            let all = try library.audioURLs(for: record)
            urls = try files.map { file in
                guard let index = record.audioFiles.firstIndex(of: file) else { throw MeetingLibraryError.missingAudio }
                return all[index]
            }
            guard !urls.isEmpty else { throw MeetingLibraryError.missingAudio }
        } catch { self.error = error.localizedDescription; return }
        record.status = .transcribing; record.recoveryMessage = nil
        do { try update(record) } catch { self.error = error.localizedDescription; return }
        transcriptionRecordingID = id
        busy = true; elapsed = 0; transcriptPhase = .recognizing
        let generation = UUID(); transcriptionGeneration = generation
        status = "正在本地识别…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
        let engine = TranscriptionEngine(); self.engine = engine
        let selectedLanguage = targetID == nil ? language : record.language
        let selectedHotwords = hotwords.words
        let initialHotwordContext = record.title + "\n" + (appending ? String(record.text.suffix(1800)) : "")
        task = Task { [self] in
            let start = Date()
            var textCommitted = false
            do {
                // 录音入口仅运行语音识别模型。
                try Task.checkCancellation()
                var outputs: [TranscriptionOutput] = []
                var durations: [Double] = []
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    status = "正在本地识别第 \(index + 1)/\(urls.count) 段录音…"
                    let duration = try await Task.detached(priority: .utility) { try CaptureRecovery.audioDuration(url) }.value
                    guard duration.isFinite, duration >= 0 else { throw TranscriptionError.message("录音时长无效。") }
                    let output = try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) {
                            try engine.transcribe(audio: url, model: model, executable: executable, language: selectedLanguage, hotwords: selectedHotwords, context: initialHotwordContext)
                        }.value
                    } onCancel: { engine.cancel() }
                    outputs.append(output); durations.append(duration)
                }
                try Task.checkCancellation()
                guard outputs.contains(where: { !$0.text.isEmpty }) else { throw TranscriptionError.message("未识别到语音。请检查音频是否有清晰人声。") }
                saveEdits()
                var latest = try library.load(id)
                try MeetingRecordingAppend.apply(outputs: outputs, files: files, durations: durations, appending: appending, to: &latest)
                latest.language = selectedLanguage
                latest.transcriptionEngine = appending && !record.text.isEmpty && record.transcriptionEngine != "qwen3-asr-1.7b-8bit"
                    ? "mixed-history-and-qwen3-asr" : "qwen3-asr-1.7b-8bit"
                latest.seconds = Date().timeIntervalSince(start); latest.status = .completed
                latest.speakerAnalysisStatus = .processing
                latest.speakerAnalysisMessage = "正文已保存，正在区分发言人。"
                try update(latest)
                textCommitted = true
                if selection == id { text = latest.text }
                var failures = 0
                for (index, url) in urls.enumerated() where !outputs[index].text.isEmpty {
                    try Task.checkCancellation()
                    do {
                        let base = outputs[index]
                        let rows = try await withTaskCancellationHandler {
                            try await Task.detached(priority: .userInitiated) {
                                try engine.analyzeSpeakers(audio: url, model: model, executable: executable, transcript: base, language: selectedLanguage,
                                    onPhase: { [weak self] phase in
                                        Task { @MainActor in
                                            guard let self, self.transcriptionGeneration == generation else { return }
                                            self.transcriptPhase = phase
                                            self.status = (phase == .diarizing ? "正在区分发言人" : "正在对齐发言人与文字") + " · 第 \(index + 1)/\(urls.count) 段录音 · 正文已保存"
                                        }
                                    })
                            }.value
                        } onCancel: { engine.cancel() }
                        try Task.checkCancellation()
                        saveEdits()
                        var analyzed = try library.load(id)
                        try MeetingRecordingAppend.applySpeakerParagraphs(rows, base: base, file: files[index], to: &analyzed)
                        try update(analyzed)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failures += 1
                        var analyzed = try library.load(id)
                        analyzed.speakerAnalysisMessage = "部分发言人分析未完成，正文已保存。" + String(error.localizedDescription.prefix(220))
                        try update(analyzed)
                    }
                }
                saveEdits()
                var analyzed = try library.load(id)
                let hasLegacy = analyzed.transcriptParagraphs.contains { $0.start == nil }
                analyzed.speakerAnalysisStatus = failures == 0 && !hasLegacy ? .completed : .partial
                if failures == 0 { analyzed.speakerAnalysisMessage = hasLegacy ? "新增录音已分人；原有正文需重新识别后才能分人。" : "最多区分4位发言人；续录标签独立，可手动改名或合并。重叠与不确定片段请核对。" }
                analyzed.seconds = Date().timeIntervalSince(start)
                try update(analyzed)
                transcriptPhase = .completed
                status = "\(appending && latest.audioFiles.count > 1 ? "续录转写已追加" : "转录完成") · 用时 \(Int(analyzed.seconds)) 秒 · 已保存到本机"

            } catch is CancellationError {
                if textCommitted {
                    saveEdits()
                    if var latest = try? library.load(id) {
                        latest.speakerAnalysisStatus = .cancelled; latest.speakerAnalysisMessage = "已取消发言人分析，正文和音频已保存。"
                        try? update(latest)
                    }
                    transcriptPhase = .completed
                    status = "已取消发言人分析 · 转录正文已保存"
                } else {
                    finishFailedTranscription(id: id, cancelled: true); transcriptPhase = .idle
                    status = "已取消转录，音频和已有文本已保留"
                }
            } catch {
                if textCommitted {
                    saveEdits()
                    if var latest = try? library.load(id) {
                        latest.speakerAnalysisStatus = .failed; latest.speakerAnalysisMessage = "发言人分析未完成，正文已保存。"
                        try? update(latest)
                    }
                    transcriptPhase = .completed
                    status = "转录已保存，发言人分析未完成"
                } else {
                    finishFailedTranscription(id: id, cancelled: false); transcriptPhase = .failed
                    reportRecoverableError(error.localizedDescription) { [weak self] in self?.transcribe(recordingID: id) }
                    status = "转录失败，可重试"
                }
            }
            transcriptionGeneration = nil
            timer?.invalidate(); timer = nil; busy = false; self.engine = nil; task = nil
            transcriptionRecordingID = nil
            if textCommitted, let completed = try? library.load(id) { hotwords.extract(from: completed.text) }
        }
    }

    private func finishFailedTranscription(id: UUID, cancelled: Bool) {
        guard var record = history.first(where: { $0.id == id }) else { return }
        record.status = cancelled ? .recorded : .failed
        do { try update(record) } catch { self.error = error.localizedDescription }
    }
    func cancel() { task?.cancel() }

    func toggleRecording() {
        guard !quitting, !preparing else { return }
        if recording { finishRecording(); return }
        startRecording(continuing: false)
    }

    func continueRecording() {
        guard !locked, !syncing, let record = current, let library else { return }
        guard saveEdits() else { return }
        let audio: [URL]
        do { audio = try library.audioURLs(for: record) }
        catch { self.error = error.localizedDescription; return }
        recoveryBusy = true
        recoveryTask = Task {
            do {
                let worker = Task.detached(priority: .utility) {
                    try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: library.directory(for: record.id),
                        managedAudio: audio, importedSessions: record.importedCaptureSessions)
                }
                let scan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                recoveryBusy = false; recoveryTask = nil
                guard current?.id == record.id else { return }
                guard scan.warnings.isEmpty else {
                    error = "部分中断录音尚未恢复，请先检查原轨：" + scan.warnings.joined(separator: "；"); return
                }
                if let candidate = scan.candidates.first { recoverCapture(candidate, continueAfterSaving: true) }
                else { startRecording(continuing: true) }
            } catch {
                recoveryBusy = false; recoveryTask = nil
                self.error = "继续录音前检查未完成：" + error.localizedDescription
            }
        }
    }

    /// 在开始新会话前固定处理策略；录音中不因窗口或设置变化关闭ASR。
    func prepareRecordingProfile() {
        guard !locked else { return }
        activeRecordingProfile = recordingProfile
        activeRecordingSessionMode = recordingSessionMode
        liveEnabled = activeRecordingProfile.usesLiveASR && (TranscriptionLanguage(rawValue:language)?.supportsLivePreview == true)
        expandedRealtime = false; pendingLivePresentation = nil
        lastLivePresentation = .distantPast; lastLiveSave = .distantPast
    }

    private func startRecording(continuing: Bool) {
        guard !busy, !preparing, !quitting, !recoveryBusy, continuousWorker == nil else { return }
        guard !recording, !syncing, let library else { return }
        speechModels.refresh()
        // Recovery may continue without installed models, but starting a new
        // session retains the existing model and engine readiness checks.
        if !continuing {
            guard speechModels.ready else { showModelDownload = true; return }
            guard model != nil, ASRResources.executable("qwen-asr") != nil,
                  !recordingProfile.usesLiveASR || (ASRResources.paraformer != nil && ASRResources.executable("paraformer-live") != nil) else {
                error = "语音引擎缺失，请重新安装 App。"; return
            }
        }
        if continuing && current == nil { return }
        if continuing, let current { recordingSessionMode = current.recordingSessionMode }
        if recordingMode.needsMicrophone {
            do { try MeetingRecorder.requireMicrophone() }
            catch { self.error = error.localizedDescription; return }
        }
        prepareRecordingProfile()
        liveEnabled = activeRecordingProfile.usesLiveASR && (TranscriptionLanguage(rawValue:continuing ? (current?.language ?? language) : language)?.supportsLivePreview == true)
        error = nil
        if activeRecordingProfile != .realtime || activeRecordingSessionMode == .continuous { showMiniRecorder() }
        continuousSegments = []
        continuousProcessingCount = 0
        recordingIssue = nil; liveLevels = [Float](repeating: 0, count: 72)
        saveEdits(); stopPlayback(); preparing = true
        Task { [self] in
            var record = continuing ? current! : MeetingRecord(title: L10n.text("录音 ") + Date().formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)), language: language, status: .recording)
            let original = record
            do {
                recordingBaseDuration = record.duration
                if activeRecordingSessionMode == .continuous {
                    let directory = library.directory(for: record.id).appendingPathComponent("Capture/Segments")
                    continuousSegments = ContinuousRecordingQueue.pending(try ContinuousRecordingQueue.load(directory), record: record)
                }
                record.recordingSessionMode = activeRecordingSessionMode
                record.status = .recording; record.recoveryMessage = nil
                try update(record)
                bindRecordingContext(to: record.id)
                continuousMeetingID = activeRecordingSessionMode == .continuous ? record.id : nil
                miniSessionID = record.id
                select(record.id)
                startLiveTranscription(for: record.id)
                let directory = library.directory(for: record.id).appendingPathComponent("Capture", isDirectory: true)
                let segmentDirectory = directory.appendingPathComponent("Segments", isDirectory: true)
                if activeRecordingSessionMode == .continuous {
                    continuousSegmenter = ContinuousRecordingSegmenter(directory: segmentDirectory, timelineOffset: recordingBaseDuration, onError: { [weak self] issue in
                        Task { @MainActor in self?.error = "持续录音切片中断，原始音轨仍在保存：\(issue.localizedDescription)" }
                    }) { [weak self] segment in
                        Task { @MainActor in self?.receiveContinuousSegment(segment) }
                    }
                }
                try await captureStarter(recorder, MeetingCaptureRequest(mode: recordingMode, directory: directory,
                    sessionMode: activeRecordingSessionMode, meetingOffset: recordingBaseDuration, segmenter: continuousSegmenter))
                activeRecordingSources = recorder.activeSources
                switchingRecordingSource = nil
                recording = true; paused = false; elapsed = 0
                status = liveEnabled ? "正在录音并实时转录 · 停止后自动生成定稿" : "正在录制\(recordingMode.title) · 停止后自动转录"
            } catch {
                liveSession?.cancel(); liveRefiner?.cancel(); liveRefiner = nil; liveSession = nil; liveGeneration = nil; recorder.onAudio = nil
                record = original
                if !continuing { record.status = .failed; record.recoveryMessage = "录音未能正常开始。" }
                do { try update(record) } catch { }
                self.error = error.localizedDescription; recordingID = nil
            }
            preparing = false
            if recording, activeRecordingSessionMode == .continuous { processNextContinuousSegment() }
        }
    }

    func findRecoverableAudio() {
        guard !locked, let record = current, let library else { return }
        saveEdits(); stopPlayback()
        recoveryBusy = true; recoveryCandidates = []; recoveryWarnings = []; recoveryStatus = "正在检查原轨与已保存音频…"
        let directory = library.directory(for: record.id)
        let audio: [URL]
        do { audio = try library.audioURLs(for: record) }
        catch { recoveryBusy = false; recoveryStatus = "检查未完成：" + error.localizedDescription; return }
        recoveryTask = Task {
            defer { recoveryBusy = false; recoveryTask = nil }
            let worker = Task.detached(priority: .utility) {
                try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: directory, managedAudio: audio,
                                         importedSessions: record.importedCaptureSessions)
            }
            do {
                let scan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                recoveryCandidates = scan.candidates; recoveryWarnings = scan.warnings
                recoveryStatus = scan.candidates.isEmpty ? "没有尚未登记的可恢复片段；已保存的音频可直接继续转录。" : "找到 \(scan.candidates.count) 个可恢复片段，原轨会保留。"
            } catch is CancellationError { recoveryStatus = "已取消检查，原始资料保留" }
            catch { recoveryStatus = "检查未完成：" + error.localizedDescription }
        }
    }
    func recoverCapture(_ candidate: CaptureRecoveryCandidate, continueAfterSaving: Bool = false) {
        guard !locked else { return }
        guard current?.id == candidate.meetingID, let library else {
            recoveryStatus = "录音已切换或本地库不可用，请关闭后重新检查。"; return
        }
        saveEdits(); stopPlayback()
        if candidate.canonical {
            recoveryBusy = true; recoveryStatus = "正在恢复分段录音…"
            recoveryTask = Task {
                defer { recoveryBusy = false; recoveryTask = nil }
                var shouldContinue = false
                do {
                    let manifest = try await CaptureRecovery.finalizeCanonical(candidate)
                    try Task.checkCancellation()
                    var record = try library.load(candidate.meetingID)
                    let originalDuration = record.duration
                    if record.recordingSessionMode == .continuous {
                        let planning = Task.detached(priority: .utility) {
                            let context = try CanonicalCaptureContext.read(candidate.directory)
                            let base = context?.meetingOffset ?? max(0, originalDuration - candidate.duration)
                            let directory = candidate.directory.deletingLastPathComponent().appendingPathComponent("Segments")
                            let reader = try CanonicalAudioReader(manifestURL: manifest)
                            let chapters = try ContinuousRecordingQueue.recover(recordingID: candidate.id,
                                frames: reader.durationFrames, meetingOffset: base, directory: directory)
                            return (base, chapters)
                        }
                        let (base, chapters) = try await planning.value
                        try Task.checkCancellation()
                        _ = try library.importAudio(manifest, into: &record, captureSession: candidate.id, persist: false)
                        for chapter in chapters {
                            _ = try library.importAudio(chapter.url, into: &record, recordingDuration: chapter.duration, captureSession: chapter.id, timelineEnd: chapter.start + chapter.duration, persist: false)
                            if let file = record.importedCaptureSessions[chapter.id.uuidString], !record.continuousSegmentFiles.contains(file) {
                                record.continuousSegmentFiles.append(file)
                            }
                        }
                        record.duration = max(originalDuration, base + candidate.duration)
                    } else {
                        _ = try library.importAudio(manifest, into: &record, recordingDuration: candidate.duration, captureSession: candidate.id, persist: false)
                    }
                    record.status = .recorded
                    record.captureWarnings.append(contentsOf: candidate.warnings)
                    record.recoveryMessage = "录音已恢复，原始片段保留，可继续转录。"
                    record = try library.save(record); publishStoredRecord(record)
                    if selection == record.id { select(record.id, saveCurrent: false) }
                    recoveryCandidates.removeAll { $0.id == candidate.id }; recoveryStatus = "录音已恢复并保存。"
                    shouldContinue = continueAfterSaving
                } catch is CancellationError { recoveryStatus = "已取消恢复，原始片段保留" }
                catch { recoveryStatus = "恢复未完成：" + error.localizedDescription }
                if shouldContinue { recoveryBusy = false; Task { @MainActor in self.continueRecording() } }
            }
            return
        }
        let destination: URL
        do { destination = try library.recoveryDestination(for: candidate.meetingID) }
        catch { recoveryStatus = "恢复未完成：" + error.localizedDescription; return }
        recoveryBusy = true; recoveryStatus = "正在合成并保存可恢复音频…"
        recoveryTask = Task {
            defer { recoveryBusy = false; recoveryTask = nil }
            var prepared = false
            var shouldContinue = false
            let worker = Task.detached(priority: .utility) { try await CaptureRecovery.prepare(candidate, destination: destination) }
            do {
                let duration = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                prepared = true
                try Task.checkCancellation()
                saveEdits()
                var record = try library.load(candidate.meetingID)
                _ = try library.registerRecovery(destination, duration: duration, session: candidate.id, warnings: candidate.warnings, into: &record)
                publishStoredRecord(record)
                if selection == record.id { select(record.id, saveCurrent: false) }
                recoveryCandidates.removeAll { $0.id == candidate.id }
                recoveryStatus = "恢复音频已保存，原文和原轨保留；关闭窗口后可继续转录。"
                shouldContinue = continueAfterSaving
            } catch {
                if prepared { try? FileManager.default.removeItem(at: destination) }
                recoveryStatus = error is CancellationError ? "已取消恢复，原轨保留" : "恢复未完成，原轨保留：" + error.localizedDescription
            }
            if shouldContinue { recoveryBusy = false; Task { @MainActor in self.continueRecording() } }
        }
    }
    func cancelRecovery() { recoveryTask?.cancel(); recoveryStatus = "正在取消，请等待当前文件操作收尾…" }

    func pauseRecording() {
        guard recording, !preparing else { return }
        if paused {
            preparing = true
            Task {
                let resumed = await recorder.resumeAfterDraining()
                paused = recorder.state == .paused
                if resumed { recordingIssue = nil }
                preparing = false
                status = paused ? "录音已暂停" : recordingIsMuted ? "静音录制" : "正在录音"
            }
            return
        }
        else { recorder.pause(); paused = true }
        status = paused ? "录音已暂停" : recordingIsMuted ? "静音录制" : "正在录音"
    }

    func toggleRecordingSource(_ kind: MeetingAudioTrack.Kind) async throws {
        guard recording, !preparing, !quitting, recordingIssue == nil, switchingRecordingSource == nil else { return }
        let id = recordingID
        switchingRecordingSource = kind
        defer { if recordingID == id { switchingRecordingSource = nil } }
        do {
            try await recorder.toggleSource(kind)
            guard recordingID == id, recording, !preparing else { throw CancellationError() }
            activeRecordingSources = recorder.activeSources
            level = 0; liveLevels = [Float](repeating: 0, count: 72)
            status = paused ? "录音已暂停" : recordingIsMuted ? "静音录制" : "正在录音"
        } catch {
            guard recordingID == id, recording, !preparing else { throw CancellationError() }
            activeRecordingSources = recorder.activeSources
            throw error
        }
    }

    private func finishRecording(finalize: Bool = true, onSaved: (() -> Void)? = nil) {
        switchingRecordingSource = nil
        preparing = true; transcriptPhase = .saving
        Task {
            var shouldFinalize = false
            var saved = false
            let stoppedID = recordingID
            do {
                let result = try await recorder.stop()
                if let segmenter = continuousSegmenter {
                    let closed = segmenter.finish()
                    for segment in closed where !continuousSegments.contains(where: { $0.id == segment.id }) {
                        receiveContinuousSegment(segment)
                    }
                    if let issue = segmenter.error {
                        recordingIssue = "持续录音切片中断：\(issue.localizedDescription)"
                    }
                }
                if let session = liveSession { liveStatus = "正在识别最后一段…"; await session.finish() }
                guard let id = recordingID, var record = history.first(where: { $0.id == id }), let library else { throw TranscriptionError.message("无法保存录音。") }
                saveEdits()
                record = history.first(where: { $0.id == id }) ?? record
                if let warning = result.warning { record.captureWarnings.append(warning) }
                if let recordingIssue, activeRecordingSessionMode == .continuous {
                    record.captureWarnings.append(recordingIssue)
                }
                if activeRecordingSessionMode == .continuous {
                    // 完整混音用于回放；识别队列只消费已经按边界关闭的片段，避免整段音频重复识别。
                    _ = try library.importAudio(result.audioURL, into: &record, recordingDuration: nil, captureSession: UUID(uuidString: result.audioURL.deletingLastPathComponent().lastPathComponent))
                    record.duration = max(record.duration, recordingBaseDuration + result.seconds)
                    record.status = .recorded
                } else {
                    _ = try library.importAudio(result.audioURL, into: &record, recordingDuration: result.seconds, captureSession: UUID(uuidString: result.audioURL.deletingLastPathComponent().lastPathComponent))
                }
                if let warning = result.warning {
                    record.recoveryMessage = "已保存中断前的音频：" + warning
                    record = try library.save(record)
                }
                record = try library.save(record)
                publishStoredRecord(record)
                if selection == id { select(id, saveCurrent: false) }
                status = result.warning == nil ? "录音已保存，可以开始转录" : "中断前音频已保存，正在处理已有录音"
                saved = true
                shouldFinalize = finalize
            } catch {
                liveSession?.cancel()
                if let id = recordingID, var record = history.first(where: { $0.id == id }) {
                    record.status = .interrupted; record.recoveryMessage = "原始音轨已保留，可从“恢复中断录音”检查并恢复可读取片段。"
                    do { try update(record) } catch { }
                }
                self.error = error.localizedDescription; status = "原始音轨已保留，请检查录音"
            }
            flushLivePresentation()
            recording = false; preparing = false; paused = false; level = 0; recordingID = nil
            if selection != stoppedID { liveText = current?.previewText ?? ""; livePartial = "" }
            recorder.onAudio = nil; liveRefiner?.cancel(); liveRefiner = nil; liveSession = nil; liveGeneration = nil
            if !finalize {
                continuousWorker?.cancel()
                continuousWorkerEngine?.cancel()
                if let continuousWorker { await continuousWorker.value }
                quitting = false
                if saved && saveBeforeQuit() { onSaved?() }
            }
            if shouldFinalize {
                if activeRecordingSessionMode == .continuous {
                    status = "持续录音已保存，继续处理剩余片段"
                    processNextContinuousSegment()
                    finishContinuousIfDrained()
                } else {
                    liveStatus = liveEnabled ? "实时预览已保存，正在生成完整定稿…" : "录音已保存，正在生成完整定稿…"
                    if let stoppedID { transcribe(recordingID: stoppedID) }
                }
            }
        }
    }

    private func receiveContinuousSegment(_ segment: ContinuousSegmentInfo) {
        guard !continuousSegments.contains(where: { $0.id == segment.id }),
              let library, let id = recordingID ?? current?.id,
              var record = history.first(where: { $0.id == id }) else { return }
        do {
            let priorDuration = record.duration
            _ = try library.importAudio(segment.url, into: &record, recordingDuration: segment.duration, captureSession: segment.id, timelineEnd: segment.start + segment.duration)
            record.duration = max(priorDuration, segment.start + segment.duration)
            if let file = record.importedCaptureSessions[segment.id.uuidString], !record.continuousSegmentFiles.contains(file) {
                record.continuousSegmentFiles.append(file)
            }
            record.status = recording ? .recording : .recorded
            record.speakerAnalysisStatus = .processing
            record.speakerAnalysisMessage = "持续录音片段正在依次定稿和识别发言人。"
            try update(record)
            continuousSegments.append(segment)
            let completed = continuousSegments.filter { $0.status == "completed" }.count
            let queued = continuousSegments.filter { $0.status == "queued" }.count
            status = "持续录音 · \(completed) 个片段已完成，\(queued) 个等待处理"
            processNextContinuousSegment()
        } catch {
            continuousSegments.append(ContinuousSegmentInfo(id: segment.id, url: segment.url, start: segment.start,
                                                            duration: segment.duration, status: "failed"))
            self.error = "持续录音片段保存失败：\(error.localizedDescription)"
        }
    }

    private func setContinuousSegmentStatus(_ id: UUID, _ status: String) {
        guard let index = continuousSegments.firstIndex(where: { $0.id == id }) else { return }
        continuousSegments[index].status = status
        continuousSegmenter?.setStatus(status, for: id)
    }

    private func processNextContinuousSegment() {
        guard continuousWorker == nil, !preparing, !quitting,
              let id = continuousMeetingID, let library,
              let segment = continuousSegments.first(where: { $0.status == "queued" || $0.status == "failed" }),
              segment.status == "queued",
              let record = history.first(where: { $0.id == id }),
              let file = record.importedCaptureSessions[segment.id.uuidString],
              record.pendingAudioFiles.contains(file), let model,
              let executable = ASRResources.executable("qwen-asr") else { return }
        let audio: URL
        do {
            guard let index = record.audioFiles.firstIndex(of: file) else { return }
            audio = try library.audioURLs(for: record)[index]
        } catch { self.error = "持续录音片段读取失败：\(error.localizedDescription)"; return }
        let engine = TranscriptionEngine()
        let selectedHotwords = hotwords.words
        let hotwordContext = record.title + "\n" + String(record.text.suffix(1800))
        continuousWorkerEngine = engine
        setContinuousSegmentStatus(segment.id, "transcribing")
        continuousWorker = Task { [self] in
            do {
                let output = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try engine.transcribe(audio: audio, model: model, executable: executable, language: record.language, hotwords: selectedHotwords, context: hotwordContext)
                    }.value
                } onCancel: { engine.cancel() }
                try Task.checkCancellation()
                if selection == id { saveEdits() }
                var latest = try library.load(id)
                try MeetingRecordingAppend.applyContinuous(output, file: file, start: segment.start, to: &latest)
                latest.transcriptionEngine = "qwen3-asr-1.7b-8bit"
                latest.speakerAnalysisStatus = .processing
                latest.speakerAnalysisMessage = "片段正文已保存，正在区分发言人。"
                try update(latest)
                if selection == id { text = latest.text }
                if !output.text.isEmpty {
                    setContinuousSegmentStatus(segment.id, "aligning")
                    do {
                        let rows = try await withTaskCancellationHandler {
                            try await Task.detached(priority: .utility) {
                                try engine.analyzeSpeakers(audio: audio, model: model, executable: executable,
                                                           transcript: output, language: record.language)
                            }.value
                        } onCancel: { engine.cancel() }
                        try Task.checkCancellation()
                        if selection == id { saveEdits() }
                        var analyzed = try library.load(id)
                        try MeetingRecordingAppend.applySpeakerParagraphs(rows, base: output, file: file, to: &analyzed)
                        try update(analyzed)
                    } catch {
                        var partial = try library.load(id)
                        partial.speakerAnalysisMessage = "片段正文已保存，发言人对齐未完成：" + String(error.localizedDescription.prefix(160))
                        try update(partial)
                        setContinuousSegmentStatus(segment.id, "partial")
                    }
                }
                if continuousSegments.first(where: { $0.id == segment.id })?.status != "partial" {
                    setContinuousSegmentStatus(segment.id, "completed")
                }
            } catch {
                setContinuousSegmentStatus(segment.id, "failed")
                status = "片段处理失败，音频仍可重试：" + String(error.localizedDescription.prefix(160))
            }
            continuousProcessingCount = continuousSegments.filter { $0.status == "completed" || $0.status == "partial" }.count
            if let refreshed = try? library.load(id) {
                var updated = refreshed
                let hasPending = !updated.pendingAudioFiles.isEmpty
                if !recording && !hasPending { updated.status = .completed }
                if continuousFailedCount > 0 { updated.speakerAnalysisStatus = .partial }
                else if recording || hasPending { updated.speakerAnalysisStatus = .processing }
                else { updated.speakerAnalysisStatus = continuousSegments.contains(where: { $0.status == "partial" || $0.status == "failed" }) ? .partial : .completed }
                try? update(updated)
            }
            continuousWorker = nil; continuousWorkerEngine = nil
            processNextContinuousSegment()
            finishContinuousIfDrained()
        }
    }

    private func finishContinuousIfDrained() {
        guard !recording, !preparing, continuousWorker == nil,
              let id = continuousMeetingID,
              var record = history.first(where: { $0.id == id }),
              record.pendingAudioFiles.isEmpty else { return }
        record.status = .completed
        record.speakerAnalysisStatus = continuousSegments.contains(where: { $0.status == "partial" || $0.status == "failed" }) ? .partial : .completed
        do { try update(record); status = "持续录音已保存，全部片段处理完成"; hotwords.extract(from: record.text) }
        catch { self.error = "保存持续录音完成状态失败：\(error.localizedDescription)" }
    }

    private func retryContinuousSegments(_ record: MeetingRecord) {
        guard let library, !record.pendingAudioFiles.isEmpty else {
            error = "没有待处理的持续录音片段。"
            return
        }
        let manifest = library.directory(for: record.id).appendingPathComponent("Capture/Segments/segments.json")
        do {
            let stored = try ContinuousRecordingQueue.load(manifest.deletingLastPathComponent())
            continuousSegments = ContinuousRecordingQueue.pending(stored, record: record)
            continuousMeetingID = record.id
            continuousProcessingCount = continuousSegments.filter { $0.status == "completed" || $0.status == "partial" }.count
            processNextContinuousSegment()
        } catch { self.error = "无法恢复持续录音片段队列：\(error.localizedDescription)" }
    }

    private func startLiveTranscription(for id: UUID) {
        liveSession?.cancel(); liveSession = nil
        livePrefix = history.first(where: { $0.id == id })?.previewText ?? ""
        liveSegmentOffset = history.first(where: { $0.id == id })?.duration ?? 0
        if var record = history.first(where: { $0.id == id }), record.liveUtterances.isEmpty,
           record.legacyLiveText.isEmpty, !record.previewText.isEmpty {
            record.legacyLiveText = record.previewText; try? update(record)
        }
        liveRefiner?.cancel(); liveRefiner = nil
        liveCommitted = []; livePendingRefinement = []; liveCurrentPartial = ""; liveHasRefinement = false; liveText = livePrefix; livePartial = ""; liveStatus = ""
        liveGeneration = UUID()
        recorder.onAudio = nil
        let sessionLanguage = history.first(where: { $0.id == id })?.language ?? language
        guard liveEnabled else { return }
        let isCantonese = sessionLanguage == "yue"
        guard let model = isCantonese ? ASRResources.qwen : ASRResources.paraformer,
              let executable = ASRResources.executable(isCantonese ? "qwen-asr" : "paraformer-live") else {
            liveStatus = "实时引擎缺失，仍会保存完整录音"; return
        }
        let generation = liveGeneration
        let session = LiveTranscriptionSession()
        session.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.liveGeneration == generation, self.recordingID == id else { return }
                self.handleLiveEvent(event, meetingID: id)
            }
        }
        do {
            try session.start(model: model, executable: executable, language: sessionLanguage, hotwords:hotwords.words)
            liveSession = session
            if !isCantonese, let qwenModel = self.model, let qwenExecutable = ASRResources.executable("qwen-asr") {
                let scratchPath = UserDefaults.standard.string(forKey: "LivePreviewScratchDirectory")
                let scratch = scratchPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
                let hints = hotwords.words
                let title = history.first(where: { $0.id == id })?.title ?? ""
                let refiner = LivePreviewRefiner(model: qwenModel, executable: qwenExecutable, language: sessionLanguage,
                    hotwords: hints, context: title, scratchRoot: scratch) { [weak self] original, refined in
                    Task { @MainActor in
                        guard let self, self.liveGeneration == generation, self.recordingID == id else { return }
                        self.applyLiveRefinement(original: original, refined: refined, hotwords: hints, meetingID: id)
                    }
                }
                liveRefiner = refiner
            }
            let refiner = liveRefiner
            recorder.onAudio = { [weak session, weak refiner] samples in refiner?.append(samples); session?.append(samples) }
            liveStatus = "正在加载本地模型，稍后显示实时文字…"
        } catch { liveStatus = "实时预览启动失败：\(error.localizedDescription)。仍会保存完整录音" }
    }

    func handleLiveEvent(_ event: LiveTranscriptEvent, meetingID: UUID) {
        if recording, recordingID == nil { bindRecordingContext(to: meetingID) }
        if let recordingID, recordingID != meetingID { return }
        switch event.type {
        case "ready": liveStatus = "实时识别已就绪 · 未定稿文字可修订"
        case "partial", "commit":
            let value = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let partial = event.type == "partial" ? value : ""
            liveCurrentPartial = partial
            if event.type == "commit", !value.isEmpty {
                let row = LiveUtterance(text: value, start: liveSegmentOffset + event.start, end: liveSegmentOffset + event.end)
                liveCommitted.append(row)
                if let refiner = liveRefiner {
                    livePendingRefinement.append(row)
                    if let first = livePendingRefinement.first, row.end - first.start >= 8 {
                        let submitted = refiner.submit(rows: livePendingRefinement, sessionOffset: liveSegmentOffset)
                        if submitted != .retry { livePendingRefinement = [] }
                    }
                }
            }
            let pieces = liveCommitted.map(\.text) + (!partial.isEmpty ? [partial] : [])
            let preview = ([livePrefix] + pieces).filter { !$0.isEmpty }.joined(separator: "\n")
            pendingLivePresentation = (preview, partial)
            // 隐藏或精简窗口只抑制呈现，不暂停音频输入、识别或已确认句保存。
            if !compactRecordingUI || ((miniWindowVisible || inlineRecorderVisible) && miniShowsCaptions) || Date().timeIntervalSince(lastLivePresentation) >= 2 { flushLivePresentation() }
            if liveStatus != "实时预览 · 停止后生成完整定稿" { liveStatus = "实时预览 · 停止后生成完整定稿" }
            let shouldSave = event.type == "commit" || Date().timeIntervalSince(lastLiveSave) >= (compactRecordingUI ? 5 : 2)
            guard shouldSave else { return }
            lastLiveSave = Date()
            if var record = history.first(where: { $0.id == meetingID }) {
                if event.type == "commit", !value.isEmpty {
                    if let row = liveCommitted.last { record.liveUtterances.append(row) }
                }
                record.previewText = preview
                let currentEngine = record.language == "yue" ? "qwen3-asr-live-bounded" :
                    (liveHasRefinement ? "paraformer-qwen-hotwords-silero-vad" : "paraformer-int8-silero-vad")
                record.previewEngine = livePrefix.isEmpty || record.previewEngine == currentEngine ? currentEngine : "mixed-history-and-live-asr"
                do { try update(record) } catch { self.error = "保存实时预览失败：\(error.localizedDescription)" }
            }
            // 实时提交仅用于转录，不再触发自动问答。
        case "error": liveStatus = "实时识别异常：" + event.text
        case "done": flushLivePresentation(); livePartial = ""; liveStatus = "实时预览已结束"
        default: break
        }
    }

    private func applyLiveRefinement(original: [LiveUtterance], refined: [TranscriptParagraph], hotwords: [String], meetingID: UUID) {
        guard let replacement = LivePreviewRefiner.replacing(rows: liveCommitted, original: original, refined: refined, hotwords: hotwords) else { NSLog("TalkTuck live refinement: result rejected"); return }
        guard var record = history.first(where: { $0.id == meetingID }),
              let stored = LivePreviewRefiner.replacing(rows: record.liveUtterances, original: original, refined: refined, hotwords: hotwords) else { return }
        record.liveUtterances = stored
        let pieces = replacement.map(\.text) + (liveCurrentPartial.isEmpty ? [] : [liveCurrentPartial])
        let preview = ([livePrefix] + pieces).filter { !$0.isEmpty }.joined(separator: "\n")
        record.previewText = preview
        record.previewEngine = "paraformer-qwen-hotwords-silero-vad"
        do {
            try update(record)
            NSLog("TalkTuck live refinement: preview updated")
            liveCommitted = replacement; liveHasRefinement = true
            pendingLivePresentation = (preview, liveCurrentPartial)
            flushLivePresentation()
        } catch { self.error = "保存实时预览失败：\(error.localizedDescription)" }
    }

    private func flushLivePresentation() {
        guard let pending = pendingLivePresentation else { return }
        livePartial = pending.partial; liveText = pending.text
        pendingLivePresentation = nil; lastLivePresentation = Date()
    }
    func showRecordingWindow() {
        restoreMainPresentation()
        NSApp.unhide(nil)
        if mainWindow == nil { openRecordingWindow?() }
        mainWindow?.deminiaturize(nil); mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口形态与录音策略独立；不停止采集，不修改 liveEnabled。
    func showMiniRecorder() {
        guard let miniController else { return }
        miniMode = true
        miniController.show()
        mainWindow?.orderOut(nil)
        mainWindowVisible = false
    }

    func restoreMainPresentation() {
        miniMode = false; expandedRealtime = true
        miniController?.hide()
    }

    func hideMiniToMenuBar() {
        miniController?.hide()
    }

    func setMiniWindowVisible(_ visible: Bool) {
        miniWindowVisible = visible
        if visible && miniShowsCaptions { flushLivePresentation() }
    }

    func setInlineRecorderVisible(_ visible: Bool) {
        inlineRecorderVisible = visible
        if visible && miniShowsCaptions { flushLivePresentation() }
    }

    func togglePlayback() {
        guard canPlayCurrentRecording, let audio else { return }
        // 手动播放器控制明确回到连续模式；不会沿用上一次点句的结束边界。
        paragraphPlaybackEnd = nil; playingParagraphID = nil
        if playing { player?.pause(); playing = false; playbackTimer?.invalidate(); return }
        do {
            if player == nil {
                player = try playbackFactory(audio)
                player?.currentTime = max(0, min(playbackTime, player?.duration ?? 0))
            }
            guard let player else { return }
            playbackDuration = player.duration
            if playbackTime >= player.duration { player.currentTime = 0 }
            try startPlayer()
        } catch { reportRecoverableError("播放失败：\(error.localizedDescription)") { [weak self] in self?.togglePlayback() } }
    }
    private func startPlayer() throws {
        guard let player else { return }
        player.volume = playbackVolume
        player.playbackEndTime = paragraphPlaybackEnd
        guard player.play() else { throw TranscriptionError.message("音频无法播放。") }
        playing = true; playbackTime = player.currentTime
        playbackTimer?.invalidate()
        // 点句只在本地检查时间边界，不调模型；20ms检查避免旧200ms轮询明显越过句尾。
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPlayback() }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func refreshPlayback() {
        guard let player else { return }
        if let ending = paragraphPlaybackEnd, player.currentTime >= ending || !player.isPlaying {
            player.pause(); player.currentTime = ending; playbackTime = ending
            playing = false; paragraphPlaybackEnd = nil; playingParagraphID = nil
            playbackTimer?.invalidate(); playbackTimer = nil
            return
        }
        playbackTime = player.currentTime; playing = player.isPlaying
        if !playing { playbackTimer?.invalidate(); playbackTimer = nil; playingParagraphID = nil }
    }
    func selectPlaybackSegment(_ index: Int) {
        stopPlayback()
        guard let current, current.audioFiles.indices.contains(index), let urls = try? library?.audioURLs(for: current) else {
            audio = nil; playbackDuration = 0; return
        }
        playbackSegment = index; audio = urls[index]
        playbackDuration = current.audioDurations[current.audioFiles[index]] ?? (current.audioFiles.count == 1 ? current.duration : 0)
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        paragraphPlaybackEnd = nil; playingParagraphID = nil
        let limit = player?.duration ?? playbackDuration
        let value = max(0, limit > 0 ? min(seconds, limit) : seconds)
        player?.currentTime = value; playbackTime = value
    }
    func stopPlayback() { paragraphPlaybackEnd = nil; playingParagraphID = nil; player?.stop(); player = nil; playing = false; playbackTime = 0; playbackTimer?.invalidate(); playbackTimer = nil }

    /// Resolve an explicit card target after saving the editor; never export another selection.
    func exportDocument(kind: String, recordingID: UUID) -> (name: String, ext: String, content: String)? {
        guard !locked, saveEdits(), let record = history.first(where: { $0.id == recordingID }) else { return nil }
        let ext = kind == "字幕" ? "srt" : kind == "Markdown" ? "md" : kind == "JSON" ? "json" : "txt"
        var content = ext == "srt" ? record.subtitles : ext == "md" ? AgentDataPublisher.presentationMarkdown(record) : record.text
        if ext == "json" {
            do { content = String(decoding: try AgentCodec.encoder().encode(AgentDataPublisher.snapshot(record, libraryRoot: storage)), as: UTF8.self) }
            catch { self.error = error.localizedDescription; return nil }
        }
        return (record.title + "." + ext, ext, content)
    }
    func export(kind: String, recordingID: UUID? = nil) {
        guard let id = recordingID ?? selection, let document = exportDocument(kind: kind, recordingID: id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: document.ext) ?? .plainText]
        panel.nameFieldStringValue = document.name
        if panel.runModal() == .OK, let url = panel.url {
            do { try document.content.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
    func export(subtitles: Bool) { export(kind: subtitles ? "字幕" : "文本") }

    var agentDataURL: URL { storage.appendingPathComponent("AgentData") }
    var agentPublicationError: String? { library?.publicationError }
    var agentCLIURL: URL { agentSetup.cliURL }
    var agentSetup: AgentSetup { AgentSetup(appURL: Bundle.main.bundleURL, dataRoot: agentDataURL) }
    var canShowAgentOnboarding: Bool {
        !locked && !syncing && error == nil && !showSettings && !showModelDownload && !showExecutionTrace && deletionRequest == nil &&
        current?.id == agentOnboardingRecordingID && current.map { $0.status == .completed && !$0.audioFiles.isEmpty && $0.pendingAudioFiles.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }
    func agentOnboardingDidAppear() {
        do { try agentOnboarding.markSeen() }
        catch { agentSetupIssue = "引导状态暂未保存，下次启动可能再次提示。" }
    }
    func dismissAgentOnboarding() { agentOnboardingDidAppear(); agentOnboardingRecordingID = nil }
    @discardableResult func copyAgentPrompt() -> Bool {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(agentSetup.prompt(interfaceLanguage: AppLanguage.shared.effective.rawValue), forType: .string) else {
            agentSetupIssue = "未能写入剪贴板，请重试。"; return false
        }
        agentSetupIssue = nil
        agentOnboardingDidAppear()
        return true
    }
    var agentInstructions: String {
        let config: [String: Any] = ["mcpServers": ["talktuck": agentSetup.mcpConfiguration]]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return AgentDataPublisher.instructions + "\n\nMCP配置示例：\n" + json + "\n\n数据目录：" + agentDataURL.path
    }
    func revealAgentData() { NSWorkspace.shared.open(agentDataURL) }
    func republishAgentData() {
        library?.republishAgentData()
        if let issue = library?.publicationError { error = issue }
        else { status = "本机Agent快照已更新" }
        objectWillChange.send()
    }
    /// 所有音频先复制到临时目录，再一次重命名交付，失败不留下半份导出。
    func exportAudio(recordingID: UUID? = nil) {
        guard !locked, let id = recordingID ?? selection else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L10n.text("导出到此文件夹")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            guard saveEdits(), let record = history.first(where: { $0.id == id }), let library else { return }
            let audio = try library.audioURLs(for: record), cache = try CanonicalAudioExport.defaultCacheRoot()
            status = "正在准备音频导出…"
            Task {
                do {
                    let destination = try await Task.detached(priority: .utility) {
                        try MeetingAudioExport.prepare(audio: audio, parent: parent, recordingID: id, cacheRoot: cache,
                            cancelled: { Task.isCancelled })
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting([destination]); status = "全部录音片段已导出"
                } catch { self.error = "音频导出失败，原始录音保留：\(error.localizedDescription)" }
            }
        } catch { self.error = "音频导出失败，原始录音保留：\(error.localizedDescription)" }
    }
    func exportAudio(to parent: URL, recordingID: UUID) throws -> URL {
        guard !locked, saveEdits(), let record = history.first(where: { $0.id == recordingID }), let library else {
            throw TranscriptionError.message("当前无法导出录音。")
        }
        let audio = try library.audioURLs(for: record)
        guard !audio.isEmpty else { throw TranscriptionError.message("没有可导出的音频。") }
        return try MeetingAudioExport.prepare(audio: audio, parent: parent, recordingID: record.id,
                                            cacheRoot: CanonicalAudioExport.defaultCacheRoot())
    }

    func deleteCurrent() {
        guard let id = selection else { return }
        requestTrash(id)
    }
    func requestTrash(_ id: UUID) {
        guard !locked, saveEdits(), let record = history.first(where: { $0.id == id }) else { return }
        deletionRequest = record
    }

    @discardableResult func confirmTrash(_ id: UUID) -> Bool {
        guard !locked, deletionRequest?.id == id, let library, saveEdits(), let record = history.first(where: { $0.id == id }) else { return false }
        do {
            try library.trash(id)
            history.removeAll { $0.id == id }
            trashedHistory = (try? library.listTrashed()) ?? ([record] + trashedHistory.filter { $0.id != id })
            if selection == id { select(nil, saveCurrent: false) }
            deletionRequest = nil
            status = "录音已移入回收站，可以恢复。"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func restoreTrash(_ id: UUID) -> Bool {
        guard !locked, let library, saveEdits() else { return false }
        do {
            let record = try library.restoreTrashed(id)
            publishStoredRecord(record)
            trashedHistory = (try? library.listTrashed()) ?? trashedHistory.filter { $0.id != id }
            select(id, saveCurrent: false)
            status = "录音已恢复，文字与托管音频均保留。"
            return true
        }
        catch { self.error = error.localizedDescription }
        return false
    }
    var dataRootURL: URL { storage }
    func revealDataRoot() { NSWorkspace.shared.open(storage) }

    func revealStorage() {
        let url = selection.flatMap { library?.directory(for: $0) } ?? storage
        NSWorkspace.shared.open(url)
    }

    func syncMeeting() {
        guard canSyncFinalTranscript else { error = "请等待完整转录定稿后再同步，实时预览不会发送。"; return }
        guard saveEdits() else { return }
        guard current?.status == .completed else { return }
        syncing = true; remoteURL = nil; syncReceipt = ""; syncFeedback = nil
        syncStatus = "正在同步，请稍候…"
        let destination = syncDestination
        let content = markdown, meetingTitle = current?.title ?? title
        Task {
            defer { syncing = false }
            do {
                let receipt: MCPSyncReceipt
                switch destination {
                case .dingtalk: receipt = try await dingTalkAccount.sync(title: meetingTitle, text: content)
                case .notion: receipt = try await notionAccount.sync(title: meetingTitle, text: content)
                case .feishu: receipt = try await feishuAccount.sync(title: meetingTitle, text: content)
                }
                remoteURL = receipt.remoteURL
                syncStatus = receipt.warning == nil ? "已同步到\(destination.rawValue)" : "已创建文档，内容待核对"
                syncReceipt = receipt.result + (receipt.warning.map { "\n" + $0 } ?? "")
                status = syncStatus
                syncFeedback = syncStatus + "\n\n" + syncReceipt
            } catch {
                syncStatus = "同步未完成，未自动重试"
                syncFeedback = syncStatus + "\n" + MCPConnectionStore.safeError(error)
            }
        }
    }

    @discardableResult func renameSpeaker(_ id: String, name: String, mergeInto target: String? = nil) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !locked, !name.isEmpty, saveEdits(), var current else { return false }
        let source = current.canonicalSpeaker(id)
        current.speakerNames[source] = name
        current.customSpeakerNameIDs.insert(source)
        if let target {
            let target = current.canonicalSpeaker(target)
            guard source != target, current.speakerNames[target] != nil else { return false }
            current.speakerAliases[source] = target
        }
        do { try update(current); return true } catch { self.error = error.localizedDescription; return false }
    }
    func mergeSpeaker(_ source: String, into target: String) {
        guard var current else { return }
        let source = current.canonicalSpeaker(source), target = current.canonicalSpeaker(target)
        guard source != target, current.speakerNames[target] != nil else { return }
        current.speakerAliases[source] = target
        do { try update(current) } catch { self.error = error.localizedDescription }
    }
    func unmergeSpeaker(_ id: String) {
        guard var current else { return }
        current.speakerAliases.removeValue(forKey: id)
        do { try update(current) } catch { self.error = error.localizedDescription }
    }
    @discardableResult func editTranscriptParagraph(_ id: UUID, text: String) -> Bool {
        guard !locked, saveEdits(), var current, current.hasCurrentParagraphs,
              let index = current.transcriptParagraphs.firstIndex(where: { $0.id == id }) else { return false }
        current.transcriptParagraphs[index].text = text
        current.text = current.paragraphText
        do { try update(current); self.text = current.text; return true } catch { self.error = error.localizedDescription; return false }
    }
    /// 段落归属独立于全局合并，正文、分隔符与时间轴保持原样。
    func assignParagraphSpeaker(_ paragraphID: UUID, speakerID: String?) {
        guard !locked else { return }
        saveEdits()
        guard var record = current, record.hasCurrentParagraphs,
              let index = record.transcriptParagraphs.firstIndex(where: { $0.id == paragraphID }) else { return }
        var ids: [String] = []
        if let speakerID {
            let target = record.canonicalSpeaker(speakerID)
            let known = Set((Array(record.speakerNames.keys) + record.transcriptParagraphs.flatMap(\.speakerIDs)).map { record.canonicalSpeaker($0) })
            guard known.contains(target) else { return }
            ids = [target]
        }
        guard record.transcriptParagraphs[index].speakerIDs != ids else { return }
        record.transcriptParagraphs[index].previousSpeakerIDs = record.transcriptParagraphs[index].speakerIDs
        record.transcriptParagraphs[index].speakerIDs = ids
        do { try update(record) } catch { self.error = error.localizedDescription }
    }
    func undoParagraphSpeaker(_ paragraphID: UUID) {
        guard !locked else { return }
        saveEdits()
        guard var record = current, record.hasCurrentParagraphs,
              let index = record.transcriptParagraphs.firstIndex(where: { $0.id == paragraphID }),
              let previous = record.transcriptParagraphs[index].previousSpeakerIDs else { return }
        record.transcriptParagraphs[index].speakerIDs = previous
        record.transcriptParagraphs[index].previousSpeakerIDs = nil
        do { try update(record) } catch { self.error = error.localizedDescription }
    }

    func canPlayTranscriptParagraph(_ paragraph: TranscriptParagraph) -> Bool {
        canPlayCurrentRecording && current?.hasCurrentParagraphs == true
            && current.flatMap { TranscriptPlaybackRange(paragraph: paragraph, record: $0) } != nil
    }
    func playTranscriptParagraph(_ paragraph: TranscriptParagraph) {
        guard let record = current, let latest = record.transcriptParagraphs.first(where: { $0.id == paragraph.id }) else { return }
        playParagraphRange(latest, record: record)
    }
    func playReadingGroup(_ id: UUID) {
        guard let record = current, record.hasCurrentParagraphs,
              let group = TranscriptReadability.groups(record.transcriptParagraphs).first(where: { $0.id == id }) else { return }
        playParagraphRange(group.combined, record: record)
    }
    private func playParagraphRange(_ latest: TranscriptParagraph, record: MeetingRecord) {
        guard canPlayTranscriptParagraph(latest), let file = latest.audioFile, let index = record.audioFiles.firstIndex(of: file) else { return }
        selectPlaybackSegment(index)
        guard let audio else { return }
        do {
            let prepared = try playbackFactory(audio)
            guard let range = TranscriptPlaybackRange(paragraph: latest, record: record, duration: prepared.duration) else {
                throw TranscriptionError.message("这段文字缺少有效的音频时间范围，无法单句回放。")
            }
            player = prepared; playbackDuration = prepared.duration
            prepared.currentTime = range.start; playbackTime = range.start
            paragraphPlaybackEnd = range.end; playingParagraphID = latest.id
            try startPlayer()
        } catch {
            stopPlayback(); self.error = "单句播放失败：\(error.localizedDescription)"
        }
    }

    /// 保存失败不得退出；空标题沿用现有名称，与日常自动保存语义一致。
    private func saveBeforeQuit() -> Bool {
        saveEdits()
        guard let current else { return true }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanTitle.isEmpty || current.title == cleanTitle) && current.text == text
    }

    /// 等待真正的取消处理收尾，避免退出时留下推理子进程或未保存的正文。
    func cancelTranscriptionAndSaveForQuit() async -> Bool {
        guard !recording, !preparing, !recoveryBusy, !syncing, !dingTalkAccount.busy, !notionAccount.busy, !feishuAccount.busy else { return false }
        quitting = true
        defer { quitting = false }
        let pending = task
        pending?.cancel()
        continuousWorker?.cancel()
        continuousWorkerEngine?.cancel()
        if let pending { await pending.value }
        if let continuousWorker { await continuousWorker.value }
        guard !busy, continuousWorker == nil else { return false }
        stopPlayback()
        return saveBeforeQuit()
    }

    func prepareToQuit() -> Bool {
        if quitting || quitPromptVisible { return false }
        let activity = QuitActivity.resolve(recording: recording, preparing: preparing, transcribing: busy || continuousWorker != nil, recovering: recoveryBusy,
            externalTask: syncing || dingTalkAccount.busy || notionAccount.busy || feishuAccount.busy)
        if activity == .idle { stopPlayback(); return saveBeforeQuit() }
        quitPromptVisible = true
        showRecordingWindow()
        QuitConfirmation.present(activity, parent: mainWindow) { [weak self] confirmed in
            guard let self else { return }
            self.quitPromptVisible = false
            guard confirmed else { return }
            switch activity {
            case .recording:
                if self.recording {
                    self.quitting = true
                    self.finishRecording(finalize: false, onSaved: { NSApp.terminate(nil) })
                } else if !self.preparing && self.saveBeforeQuit() { NSApp.terminate(nil) }
            case .transcribing:
                Task { if await self.cancelTranscriptionAndSaveForQuit() { NSApp.terminate(nil) } }
            default: break
            }
        }
        return false
    }
}

// 分类操作与正文保存分开；分组删除只影响关联，不删除录音。
extension AppState {
    @discardableResult func saveCollection(name: String, id: UUID? = nil, inlineErrors: Bool = false) -> Bool {
        organizationIssue = nil
        guard !locked, let library, saveEdits() else { return false }
        do {
            var next = organization
            let owner: UUID? = id != nil ? next.group(id)?.userId : cloudAccount.userId
            _ = try next.setName(name, id: id, owner: owner)
            try library.saveOrganization(next)
            organization = next; history = try library.list()
            return true
        } catch { organizationIssue = "保存分类失败：\(error.localizedDescription)"; if !inlineErrors { self.error = organizationIssue }; return false }
    }
    @discardableResult func removeCollection(_ id: UUID) -> Bool {
        guard !locked, let library, saveEdits() else { return false }
        do {
            var next = organization
            next.groups.removeAll { $0.id == id }
            // 删除分组时持久清除关联，保留每条原音。
            try library.saveOrganization(next)
            for var record in try library.list() where record.groupID == id { record.groupID = nil; _ = try library.save(record) }
            organization = next; history = try library.list(); trashedHistory = try library.listTrashed()
            if groupFilter == id.uuidString { groupFilter = "" }
            return true
        } catch { self.error = "移除分类失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult func setGroup(_ id: UUID?, recordIDs: Set<UUID>) -> Bool {
        guard id == nil || organization.group(id) != nil else { return false }
        if let id, let group = organization.group(id), history.contains(where: { recordIDs.contains($0.id) && $0.userId != group.userId }) { return false }
        return changeOrganization(recordIDs) { $0.groupID = id }
    }
    private func changeOrganization(_ ids: Set<UUID>, change: (inout MeetingRecord) -> Void) -> Bool {
        guard !locked, !ids.isEmpty, ids.isSubset(of: Set(history.map(\.id))), saveEdits() else { return false }
        var saved = 0
        do {
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard var record = history.first(where: { $0.id == id }) else { continue }
                change(&record); try update(record); saved += 1
            }
            status = "已整理 \(saved) 条录音"; return true
        } catch { self.error = "已保存 \(saved)/\(ids.count) 条，其他录音未修改：\(error.localizedDescription)"; return false }
    }
}
