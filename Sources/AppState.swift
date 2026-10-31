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
    @Published var selection: UUID?
    @Published var text = ""
    @Published var notes = ""
    @Published var summary = ""
    @Published var title = ""
    @Published var search = ""
    @Published var audio: URL?
    @Published var playbackSegment = 0
    @Published var language = "zh"
    @Published var busy = false
    @Published var recording = false
    @Published var preparing = false
    @Published private(set) var quitting = false
    @Published var paused = false
    @Published var recordingMode: MeetingRecordingMode = .microphone
    @Published var level: Float = 0
    @Published var liveLevels = [Float](repeating: 0, count: 72)
    @Published var recordingIssue: String?
    @Published private(set) var recoveryBusy = false
    @Published private(set) var recoveryCandidates: [CaptureRecoveryCandidate] = []
    @Published private(set) var recoveryWarnings: [String] = []
    @Published private(set) var recoveryStatus = ""
    private var recoveryTask: Task<Void, Never>?
    @Published var status = "准备就绪 · 音频仅在这台 Mac 上处理"
    @Published var error: String?
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
    let speechModels: ASRModelStore
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
    @Published private(set) var miniSessionID: UUID?
    var compactRecordingUI: Bool { recording && activeRecordingProfile.compact(windowVisible: mainWindowVisible, expanded: expandedRealtime) }
    private var pendingLivePresentation: (text: String, partial: String)?
    private var lastLivePresentation = Date.distantPast
    private var lastLiveSave = Date.distantPast
    @Published var liveEnabled = true
    @Published var liveQAEnabled = false {
        didSet {
            if liveQAEnabled { liveQALastRun = Date(); liveQACommitCursor = liveCommitted.count }
            else if assistantAutomatic { cancelAssistant() }
        }
    }
    private var liveQALastRun = Date()
    private var liveQACommitCursor = 0
    private var assistantAutomatic = false
    private var lastAutomaticAnswer = ""
    @Published var liveText = ""
    @Published var livePartial = ""
    @Published var transcriptPhase: TranscriptPhase = .idle
    private var transcriptionGeneration: UUID?
    private var liveSegmentOffset: Double = 0
    @Published var liveStatus = ""
    @Published var enhancedNotes = ""
    @Published var assistantBusy = false
    @Published var assistantDraft = ""
    @Published var assistantStatus = ""
    @Published var assistantModelAvailable = false
    @Published var assistantOperation = ""
    private var assistantTask: Task<Void, Never>?
    private var assistantGeneration: UUID?
    let dingTalkAccount: DingTalkAccountConnection
    let notionAccount: NotionAccountConnection
    let feishuAccount: FeishuAccountConnection
    let dingTalk: MCPConnectionStore
    let feishu: MCPConnectionStore
    let notion: MCPConnectionStore
    private let recorder = MeetingRecorder()
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
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var engine: TranscriptionEngine?
    private var recordingID: UUID?
    private var library: MeetingLibrary?
    private var autosave: Task<Void, Never>?
    private var accountSubscriptions = Set<AnyCancellable>()
    private var recordAIControlTimer: Timer?
    private var liveSession: LiveTranscriptionSession?
    private var liveGeneration: UUID?
    private var liveCommitted: [String] = []
    private var livePrefix = ""
    private let storage: URL
    var model: URL? { speechModels.ready ? ASRResources.qwen : nil }

    var recordingLiveUtterances: [LiveUtterance] { (current?.liveUtterances ?? []).filter { $0.start >= liveSegmentOffset - 0.001 } }
    var current: MeetingRecord? { history.first { $0.id == selection } }
    var syncStore: MCPConnectionStore {
        switch syncDestination { case .dingtalk: return dingTalk; case .feishu: return feishu; case .notion: return notion }
    }
    var filteredHistory: [MeetingRecord] {
        guard !search.isEmpty else { return history }
        return history.filter { [$0.title, $0.text].joined(separator: "\n").localizedStandardContains(search) }
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
        current.text = text; current.notes = notes; current.summary = summary.isEmpty ? nil : summary
        current.enhancedNotes = enhancedNotes
        return AgentDataPublisher.markdown(current)
    }

    init(storageURL: URL? = nil, connectionNamespace: String = "") {
        storage = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoHearTranscribe", isDirectory: true)
        speechModels = ASRModelStore()
        dingTalk = MCPConnectionStore(namespace: connectionNamespace + "dingtalk")
        feishu = MCPConnectionStore(namespace: connectionNamespace + "feishu")
        notion = MCPConnectionStore(namespace: connectionNamespace + "notion")
        dingTalkAccount = DingTalkAccountConnection()
        notionAccount = NotionAccountConnection(store: notion)
        feishuAccount = FeishuAccountConnection()
        speechModels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &accountSubscriptions)
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
            library = try MeetingLibrary(root: storage)
            history = try library?.list() ?? []
            if let warnings = library?.warnings, !warnings.isEmpty { error = warnings.joined(separator: "\n") }
        } catch { self.error = "读取会议库失败：\(error.localizedDescription)" }
        recorder.onUpdate = { [weak self] seconds, level in
            guard let self else { return }
            if self.elapsed != Int(seconds) { self.elapsed = Int(seconds) }
            guard !self.compactRecordingUI || self.miniWindowVisible else { return }
            self.level = level
            if self.recording && !self.paused { self.liveLevels.append(level); self.liveLevels = Array(self.liveLevels.suffix(72)) }
        }
        recorder.onError = { [weak self] error in
            self?.liveQAEnabled = false
            self?.paused = true; self?.recordingIssue = error.localizedDescription
            self?.status = "录音已暂停。请处理提示后重试，或停止并保存。"
        }
        recordAIControlTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processRecordAICommands() }
        }
    }

    private func processRecordAICommands() {
        for (url, command) in RecordAIControlQueue.pending(root: storage.appendingPathComponent("AgentData")) {
            var result = ""
            switch command.action {
            case "start_recording":
                if !recording { toggleRecording(); result = "录音启动请求已接受" } else { result = "已经在录音" }
            case "stop_recording":
                if recording { toggleRecording(); result = "录音停止请求已接受" } else { result = "当前没有录音" }
            case "pause_recording":
                if recording && !paused { pauseRecording(); result = "录音暂停请求已接受" } else { result = paused ? "已经暂停" : "当前没有录音" }
            case "resume_recording":
                if recording && paused { pauseRecording(); result = "录音继续请求已接受" } else { result = "当前不需要继续录音" }
            case "retry_transcription":
                if let current, !recording, current.audioFiles.isEmpty == false { transcribe(); result = "转录重试请求已接受" } else { result = "当前没有可重试音频" }
            default: result = "未识别控制动作"
            }
            RecordAIControlQueue.finish(url, root: storage.appendingPathComponent("AgentData"), result: result)
        }
    }

    private func update(_ record: MeetingRecord) throws {
        guard let library else { throw TranscriptionError.message("本地会议库不可用。") }
        let saved = try library.save(record)
        publishStoredRecord(saved)
    }

    private func publishStoredRecord(_ saved: MeetingRecord) {
        if let index = history.firstIndex(where: { $0.id == saved.id }) { history[index] = saved }
        else { history.insert(saved, at: 0) }
    }

    func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000); try Task.checkCancellation(); self?.saveEdits() } catch { }
        }
    }

    func saveEdits() {
        autosave?.cancel(); autosave = nil
        guard var current else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTitle = cleanTitle.isEmpty ? current.title : cleanTitle
        guard current.title != savedTitle || current.text != text || current.notes != notes || (current.summary ?? "") != summary || current.enhancedNotes != enhancedNotes else { return }
        current.title = savedTitle; current.text = text; current.notes = notes; current.summary = summary.isEmpty ? nil : summary
        current.enhancedNotes = enhancedNotes
        do { try update(current) } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    func select(_ id: UUID?, saveCurrent: Bool = true) {
        if saveCurrent { saveEdits() }
        if id != selection { cancelAssistant() }
        stopPlayback()
        selection = id
        title = current?.title ?? ""; text = current?.text ?? ""
        notes = current?.notes ?? ""; summary = current?.summary ?? ""
        liveText = current?.previewText ?? ""
        enhancedNotes = current?.enhancedNotes ?? ""
        if !recording { livePartial = "" }
        if !busy && !recording { transcriptPhase = current?.status == .completed ? .completed : .idle }
        assistantDraft = ""
        if !liveText.isEmpty && !recording { liveStatus = "录音时实时结果 · 未定稿，仅供回顾" }
        playbackSegment = max(0, (current?.audioFiles.count ?? 1) - 1)
        selectPlaybackSegment(playbackSegment)
        if let message = current?.recoveryMessage { status = message }
    }

    func chooseAudio() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.message = "导入音频后会在本机保存副本，文件不会上传。"
        if panel.runModal() == .OK, let url = panel.url { useAudio(url) }
    }

    func useAudio(_ url: URL) {
        guard !locked, let library else { return }
        saveEdits()
        do {
            var record = MeetingRecord(title: url.deletingPathExtension().lastPathComponent, language: language, status: .recorded)
            _ = try library.importAudio(url, into: &record)
            try update(record)
            select(record.id)
            status = "音频已保存在会议库，可以开始转录"
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
        } catch { self.error = "导入失败：\(error.localizedDescription)" }
    }

    func transcribe() {
        speechModels.refresh()
        guard model != nil else { showModelDownload = true; return }
        guard let model, !locked, var record = current, let library else { return }
        if record.recordingSessionMode == .continuous {
            retryContinuousSegments(record)
            return
        }
        guard let executable = ASRResources.executable("qwen-asr") else {
            error = "安装包缺少转录引擎。"; return
        }
        saveEdits(); stopPlayback()
        record = current ?? record
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
        cancelAssistant()
        busy = true; elapsed = 0; transcriptPhase = .recognizing
        let generation = UUID(); transcriptionGeneration = generation
        status = "正在本地识别，音频不会上传…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
        let engine = TranscriptionEngine(); self.engine = engine
        let selectedLanguage = language
        task = Task { [self] in
            let start = Date()
            var textCommitted = false
            do {
                // 录音入口仅运行语音模型，不启动或预热Gemma。
                try Task.checkCancellation()
                var outputs: [TranscriptionOutput] = []
                var durations: [Double] = []
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    status = "正在本地识别第 \(index + 1)/\(urls.count) 段录音…"
                    let duration = try await AVURLAsset(url: url).load(.duration).seconds
                    guard duration.isFinite, duration >= 0 else { throw TranscriptionError.message("录音时长无效。") }
                    let output = try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) {
                            try engine.transcribe(audio: url, model: model, executable: executable, language: selectedLanguage)
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
                if appending && latest.audioFiles.count > 1 && latest.summary != nil {
                    assistantStatus = "已追加新录音；已有摘要保留，请重新生成以覆盖新增讨论。"
                }
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
                    self.error = error.localizedDescription; status = "转录失败，可重试"
                }
            }
            transcriptionGeneration = nil
            timer?.invalidate(); timer = nil; busy = false; self.engine = nil; task = nil
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

    func continueRecording() { startRecording(continuing: true) }

    /// 在开始新会话前固定处理策略；录音中不因窗口或设置变化关闭ASR。
    func prepareRecordingProfile() {
        guard !locked else { return }
        activeRecordingProfile = recordingProfile
        activeRecordingSessionMode = recordingSessionMode
        liveEnabled = activeRecordingProfile.usesLiveASR
        expandedRealtime = false; pendingLivePresentation = nil
        lastLivePresentation = .distantPast; lastLiveSave = .distantPast
    }

    private func startRecording(continuing: Bool) {
        guard !busy, !preparing, !quitting, !recoveryBusy, continuousWorker == nil else { return }
        guard !recording, !syncing, let library else { return }
        speechModels.refresh()
        guard speechModels.ready else { showModelDownload = true; return }
        guard model != nil, ASRResources.executable("qwen-asr") != nil,
              !recordingProfile.usesLiveASR || (ASRResources.paraformer != nil && ASRResources.executable("paraformer-live") != nil) else {
            error = "语音引擎缺失，请重新安装 App。"; return
        }
        if continuing && current == nil { return }
        if continuing, let current, recordingSessionMode == .continuous, !current.pendingAudioFiles.isEmpty {
            error = "这条持续录音还有待处理片段，请先重试转录。"; return
        }
        if continuing, let current, current.pendingAudioFiles.isEmpty, !current.audioFiles.isEmpty, current.text.isEmpty {
            error = "已有录音尚未完成转录，请先转录已有录音。"; return
        }
        if recordingMode.needsMicrophone {
            do { try MeetingRecorder.requireMicrophone() }
            catch { self.error = error.localizedDescription; return }
        }
        prepareRecordingProfile()
        error = nil
        if activeRecordingProfile != .realtime || activeRecordingSessionMode == .continuous { showMiniRecorder() }
        continuousSegments = []
        continuousProcessingCount = 0
        recordingIssue = nil; liveLevels = [Float](repeating: 0, count: 72)
        liveQALastRun = Date(); liveQACommitCursor = 0; lastAutomaticAnswer = ""
        cancelAssistant(); saveEdits(); stopPlayback(); preparing = true
        Task { [self] in
            var record = continuing ? current! : MeetingRecord(title: "会议 " + Date().formatted(date: .numeric, time: .shortened), language: language, status: .recording)
            let original = record
            do {
                record.recordingSessionMode = activeRecordingSessionMode
                record.status = .recording; record.recoveryMessage = nil
                try update(record)
                recordingID = record.id
                continuousMeetingID = activeRecordingSessionMode == .continuous ? record.id : nil
                miniSessionID = record.id
                select(record.id)
                startLiveTranscription(for: record.id)
                let directory = library.directory(for: record.id).appendingPathComponent("Capture", isDirectory: true)
                let segmentDirectory = directory.appendingPathComponent("Segments", isDirectory: true)
                if activeRecordingSessionMode == .continuous {
                    continuousSegmenter = ContinuousRecordingSegmenter(directory: segmentDirectory, onError: { [weak self] issue in
                        Task { @MainActor in self?.error = "持续录音切片中断，原始音轨仍在保存：\(issue.localizedDescription)" }
                    }) { [weak self] segment in
                        Task { @MainActor in self?.receiveContinuousSegment(segment) }
                    }
                }
                try await recorder.start(mode: recordingMode, directory: directory,
                                         sessionMode: activeRecordingSessionMode,
                                         segmenter: continuousSegmenter)
                recording = true; paused = false; elapsed = 0
                status = liveEnabled ? "正在录音并实时转录 · 停止后自动生成定稿" : "正在录制\(recordingMode.title) · 停止后自动转录"
            } catch {
                liveQAEnabled = false
                liveSession?.cancel(); liveSession = nil; liveGeneration = nil; recorder.onAudio = nil
                record = original
                if !continuing { record.status = .failed; record.recoveryMessage = "录音未能正常开始。" }
                do { try update(record) } catch { }
                self.error = error.localizedDescription; recordingID = nil
            }
            preparing = false
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
    func recoverCapture(_ candidate: CaptureRecoveryCandidate) {
        guard !locked else { return }
        guard current?.id == candidate.meetingID, let library else {
            recoveryStatus = "录音已切换或本地库不可用，请关闭后重新检查。"; return
        }
        saveEdits(); stopPlayback()
        let destination: URL
        do { destination = try library.recoveryDestination(for: candidate.meetingID) }
        catch { recoveryStatus = "恢复未完成：" + error.localizedDescription; return }
        recoveryBusy = true; recoveryStatus = "正在合成并保存可恢复音频…"
        recoveryTask = Task {
            defer { recoveryBusy = false; recoveryTask = nil }
            var prepared = false
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
            } catch {
                if prepared { try? FileManager.default.removeItem(at: destination) }
                recoveryStatus = error is CancellationError ? "已取消恢复，原轨保留" : "恢复未完成，原轨保留：" + error.localizedDescription
            }
        }
    }
    func cancelRecovery() { recoveryTask?.cancel(); recoveryStatus = "正在取消，请等待当前文件操作收尾…" }

    func pauseRecording() {
        guard recording, !preparing else { return }
        if paused {
            let resumed = recorder.resume()
            paused = recorder.state == .paused
            if resumed { recordingIssue = nil }
        }
        else { recorder.pause(); paused = true }
        status = paused ? "录音已暂停" : "正在录制\(recordingMode.title)"
    }

    private func finishRecording(finalize: Bool = true, onSaved: (() -> Void)? = nil) {
        liveQAEnabled = false
        preparing = true; transcriptPhase = .saving
        Task {
            var shouldFinalize = false
            var saved = false
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
                guard let id = recordingID, var record = history.first(where: { $0.id == id }), let library else { throw TranscriptionError.message("无法保存会议录音。") }
                saveEdits()
                record = history.first(where: { $0.id == id }) ?? record
                if let warning = result.warning { record.captureWarnings.append(warning) }
                if let recordingIssue, activeRecordingSessionMode == .continuous {
                    record.captureWarnings.append(recordingIssue)
                }
                if activeRecordingSessionMode == .continuous {
                    // 完整混音用于回放；识别队列只消费已经按边界关闭的片段，避免整段音频重复识别。
                    _ = try library.importAudio(result.audioURL, into: &record, recordingDuration: nil, captureSession: UUID(uuidString: result.audioURL.deletingLastPathComponent().lastPathComponent))
                    record.duration = max(record.duration, result.seconds)
                    record.status = .recorded
                } else {
                    _ = try library.importAudio(result.audioURL, into: &record, recordingDuration: result.seconds, captureSession: UUID(uuidString: result.audioURL.deletingLastPathComponent().lastPathComponent))
                }
                if let warning = result.warning {
                    record.recoveryMessage = "已保存中断前的音频：" + warning
                    record = try library.save(record)
                }
                publishStoredRecord(record)
                select(id)
                status = result.warning == nil ? "会议录音已保存，可以开始转录" : "中断前音频已保存，正在处理已有录音"
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
            recorder.onAudio = nil; liveSession = nil; liveGeneration = nil
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
                    liveStatus = activeRecordingProfile.usesLiveASR ? "实时预览已保存，正在生成完整定稿…" : "录音已保存，正在生成完整定稿…"; transcribe()
                }
            }
        }
    }

    private func receiveContinuousSegment(_ segment: ContinuousSegmentInfo) {
        guard !continuousSegments.contains(where: { $0.id == segment.id }),
              let library, let id = recordingID ?? current?.id,
              var record = history.first(where: { $0.id == id }) else { return }
        do {
            _ = try library.importAudio(segment.url, into: &record, recordingDuration: segment.duration, captureSession: segment.id)
            record.duration = max(record.duration, segment.start + segment.duration)
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
        continuousWorkerEngine = engine
        setContinuousSegmentStatus(segment.id, "transcribing")
        continuousWorker = Task { [self] in
            do {
                let output = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try engine.transcribe(audio: audio, model: model, executable: executable, language: record.language)
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
        do { try update(record); status = "持续录音已保存，全部片段处理完成" }
        catch { self.error = "保存持续录音完成状态失败：\(error.localizedDescription)" }
    }

    private func retryContinuousSegments(_ record: MeetingRecord) {
        guard let library, !record.pendingAudioFiles.isEmpty else {
            error = "没有待处理的持续录音片段。"
            return
        }
        let manifest = library.directory(for: record.id).appendingPathComponent("Capture/Segments/segments.json")
        do {
            let stored = try JSONDecoder().decode([ContinuousSegmentInfo].self, from: Data(contentsOf: manifest))
            continuousSegments = stored.map { segment in
                var item = segment
                if let file = record.importedCaptureSessions[segment.id.uuidString], record.pendingAudioFiles.contains(file) {
                    item.status = "queued"
                }
                return item
            }
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
        liveCommitted = []; liveText = livePrefix; livePartial = ""; liveStatus = ""
        liveGeneration = UUID()
        recorder.onAudio = nil
        guard liveEnabled else { return }
        guard let model = ASRResources.paraformer, let executable = ASRResources.executable("paraformer-live") else {
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
            try session.start(model: model, executable: executable, language: language)
            liveSession = session
            recorder.onAudio = { [weak session] samples in session?.append(samples) }
            liveStatus = "正在加载本地模型，稍后显示实时文字…"
        } catch { liveStatus = "实时预览启动失败：\(error.localizedDescription)。仍会保存完整录音" }
    }

    func handleLiveEvent(_ event: LiveTranscriptEvent, meetingID: UUID) {
        switch event.type {
        case "ready": liveStatus = "实时识别已就绪 · 未定稿文字可修订"
        case "partial", "commit":
            let value = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let partial = event.type == "partial" ? value : ""
            if event.type == "commit", !value.isEmpty { liveCommitted.append(value) }
            let pieces = liveCommitted + (!partial.isEmpty ? [partial] : [])
            let preview = ([livePrefix] + pieces).filter { !$0.isEmpty }.joined(separator: "\n")
            pendingLivePresentation = (preview, partial)
            // 隐藏或精简窗口只抑制呈现，不暂停音频输入、识别或已确认句保存。
            if !compactRecordingUI || Date().timeIntervalSince(lastLivePresentation) >= 2 { flushLivePresentation() }
            if liveStatus != "实时预览 · 停止后生成完整定稿" { liveStatus = "实时预览 · 停止后生成完整定稿" }
            let shouldSave = event.type == "commit" || Date().timeIntervalSince(lastLiveSave) >= (compactRecordingUI ? 5 : 2)
            guard shouldSave else { return }
            lastLiveSave = Date()
            if var record = history.first(where: { $0.id == meetingID }) {
                if event.type == "commit", !value.isEmpty {
                    record.liveUtterances.append(LiveUtterance(text: value, start: liveSegmentOffset + event.start, end: liveSegmentOffset + event.end))
                }
                record.previewText = preview
                record.previewEngine = livePrefix.isEmpty || record.previewEngine == "paraformer-int8-silero-vad"
                    ? "paraformer-int8-silero-vad" : "mixed-history-and-paraformer"
                do { try update(record) } catch { self.error = "保存实时预览失败：\(error.localizedDescription)" }
            }
            // 实时提交仅用于转录，不再触发自动问答。
        case "error": liveQAEnabled = false; liveStatus = "实时识别异常：" + event.text
        case "done": flushLivePresentation(); livePartial = ""; liveStatus = "实时预览已结束"
        default: break
        }
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

    func setMiniWindowVisible(_ visible: Bool) { miniWindowVisible = visible }

    func togglePlayback() {
        guard !recording, !preparing, let audio else { return }
        // 手动播放器控制明确回到连续模式；不会沿用上一次点句的结束边界。
        paragraphPlaybackEnd = nil; playingParagraphID = nil
        if playing { player?.pause(); playing = false; playbackTimer?.invalidate(); return }
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: audio)
                player?.currentTime = max(0, min(playbackTime, player?.duration ?? 0))
            }
            guard let player else { return }
            playbackDuration = player.duration
            if playbackTime >= player.duration { player.currentTime = 0 }
            try startPlayer()
        } catch { self.error = "播放失败：\(error.localizedDescription)" }
    }
    private func startPlayer() throws {
        guard let player else { return }
        player.volume = playbackVolume
        guard player.play() else { throw TranscriptionError.message("音频无法播放。") }
        playing = true; playbackTime = player.currentTime
        playbackTimer?.invalidate()
        // 点句只在本地检查时间边界，不调模型；20ms检查避免旧200ms轮询明显越过句尾。
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayback() }
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

    func export(kind: String) {
        saveEdits(); guard let current else { return }
        let ext = kind == "字幕" ? "srt" : kind == "Markdown" ? "md" : kind == "JSON" ? "json" : "txt"
        var content = ext == "srt" ? current.subtitles : ext == "md" ? markdown : text
        if ext == "json" {
            do { content = String(decoding: try AgentCodec.encoder().encode(AgentDataPublisher.snapshot(current, libraryRoot: storage)), as: UTF8.self) }
            catch { self.error = error.localizedDescription; return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = current.title + "." + ext
        if panel.runModal() == .OK, let url = panel.url {
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
    func export(subtitles: Bool) { export(kind: subtitles ? "字幕" : "文本") }

    var agentDataURL: URL { storage.appendingPathComponent("AgentData") }
    var agentPublicationError: String? { library?.publicationError }
    var agentCLIURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cohear") }
    var agentInstructions: String {
        let config: [String: Any] = ["mcpServers": ["cohear": ["command": agentCLIURL.path, "args": ["mcp"]]]]
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
    func exportAudio() {
        guard !locked, let current, let library else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "导出到此文件夹"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let temporary = parent.appendingPathComponent(".cohear-export-" + UUID().uuidString)
        let destination = parent.appendingPathComponent("录音-" + current.id.uuidString + "-" + String(Int(Date().timeIntervalSince1970)))
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            for (index, url) in try library.audioURLs(for: current).enumerated() {
                try FileManager.default.copyItem(at: url, to: temporary.appendingPathComponent(String(format: "%02d", index + 1) + "-" + url.lastPathComponent))
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination]); status = "全部录音片段已导出"
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            self.error = "音频导出失败，原始录音保留：\(error.localizedDescription)"
        }
    }

    func deleteCurrent() {
        guard let selection, !locked else { return }
        let alert = NSAlert()
        alert.messageText = "将这场会议移到废纸篓？"
        alert.informativeText = "会议文本和托管音频将一起移入废纸篓；导入前的源文件会保留。"
        alert.addButton(withTitle: "移到废纸篓"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try library?.trash(selection); history.removeAll { $0.id == selection }; select(nil) }
        catch { self.error = error.localizedDescription }
    }
    var dataRootURL: URL { storage }
    func revealDataRoot() { NSWorkspace.shared.open(storage) }

    func revealStorage() {
        let url = selection.flatMap { library?.directory(for: $0) } ?? storage
        NSWorkspace.shared.open(url)
    }

    func syncMeeting() {
        guard canSyncFinalTranscript else { error = "请等待完整转录定稿后再同步，实时预览不会发送。"; return }
        saveEdits()
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

    func refreshAssistantAvailability() {
        assistantModelAvailable = GemmaRuntime.configurationAvailable()
    }

    func generateSummary() { runAssistant(operation: "摘要") }
    func enhanceMeetingNotes() { runAssistant(operation: "增强笔记") }
    func askAssistant(_ question: String, live: Bool) { runAssistant(operation: live ? "Live Q&A" : "对话", question: question, live: live) }
    func findLiveQuestions() { runAssistant(operation: "Live Q&A", question: "从当前讨论中识别问题", live: true, discover: true) }

    func cancelAssistant() {
        let wasBusy = assistantBusy
        assistantTask?.cancel(); assistantTask = nil; assistantGeneration = nil
        if wasBusy { Task { await GemmaRuntime.shared.cancel() } }
        assistantBusy = false; assistantAutomatic = false; assistantDraft = ""; assistantStatus = wasBusy ? "已取消，已有内容保留" : ""
    }

    private func scheduleLiveQuestions() {
        refreshAssistantAvailability()
        let pending = liveCommitted.dropFirst(min(liveQACommitCursor, liveCommitted.count)).joined(separator: "\n")
        let now = Date()
        guard LiveQASchedule.shouldRun(now: now, lastRun: liveQALastRun, enabled: liveQAEnabled,
            recording: recording, paused: paused, preparing: preparing, assistantBusy: assistantBusy,
            modelReady: assistantModelAvailable, pendingText: pending) else { return }
        liveQALastRun = now; liveQACommitCursor = liveCommitted.count
        runAssistant(operation: "Live Q&A", question: "自动发现讨论中的问题", live: true, discover: true,
                     automatic: true, materialOverride: String(pending.suffix(3000)))
    }

    private func runAssistant(operation: String, question: String = "", live: Bool = false, discover: Bool = false,
                              automatic: Bool = false, materialOverride: String? = nil) {
        refreshAssistantAvailability()
        guard !busy else { assistantStatus = "正在生成语音定稿，完成后可使用会议助手。"; return }
        guard assistantModelAvailable else { error = "请先在设置 → 辅助模型中下载并启用 Gemma。"; return }
        guard !assistantBusy, let meetingID = current?.id else { return }
        saveEdits()
        let fallbackToLive = !live && operation != "摘要" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sourceIsLive = live || fallbackToLive
        let material = materialOverride ?? (sourceIsLive ? liveText : text)
        let input = MeetingIntelligenceInput(title: title, transcript: material, notes: automatic ? "" : notes, isLive: sourceIsLive)
        let generation = UUID(); assistantGeneration = generation
        assistantAutomatic = automatic
        assistantBusy = true; assistantDraft = ""; assistantOperation = operation; assistantStatus = "正在加载本地 Gemma 并生成…"
        let service = MeetingIntelligence { system, prompt, onToken in
            try await GemmaRuntime.shared.generate(system: system, prompt: prompt, onToken: onToken)
        }
        assistantTask = Task { [weak self] in
            guard let self else { return }
            let onToken: @Sendable (String) -> Void = { [weak self] token in
                Task { @MainActor in
                    guard let self, self.assistantGeneration == generation, self.selection == meetingID else { return }
                    self.assistantDraft += token
                }
            }
            do {
                let result: MeetingIntelligenceResult
                if operation == "摘要" {
                    result = try await service.summarize(input, onToken: onToken, onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.assistantGeneration == generation, self.selection == meetingID else { return }
                            self.assistantStatus = "Gemma · " + progress
                        }
                    })
                }
                else if operation == "增强笔记" { result = try await service.enhanceNotes(input, onToken: onToken) }
                else if discover { result = try await service.liveQuestions(input, onToken: onToken) }
                else { result = try await service.answer(question: question, input: input, onToken: onToken) }
                try Task.checkCancellation()
                guard self.assistantGeneration == generation, self.selection == meetingID else { return }
                if automatic {
                    let answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if answer.contains("当前片段未发现明确问题") || answer == self.lastAutomaticAnswer {
                        self.assistantStatus = "当前片段未发现新问题 · 自动检查已完成"
                        self.assistantDraft = ""; self.assistantBusy = false; self.assistantAutomatic = false
                        self.assistantGeneration = nil; self.assistantTask = nil
                        return
                    }
                    self.lastAutomaticAnswer = answer
                }
                self.saveEdits()
                guard var record = self.current else { return }
                let cited = result.citedSources.map {
                    MeetingCitation(id: $0.id, kind: $0.kind.rawValue, text: $0.text)
                }
                if operation == "摘要" { record.summary = result.text; record.summaryCitations = cited; record.summaryContextWasTruncated = result.contextWasTruncated; self.summary = result.text }
                else if operation == "增强笔记" { record.enhancedNotes = sourceIsLive ? "【实时文字 · 未定稿】\n" + result.text : result.text; record.enhancedNotesCitations = cited; record.enhancedNotesContextWasTruncated = result.contextWasTruncated; self.enhancedNotes = record.enhancedNotes }
                else { record.assistantEntries.append(MeetingAssistantEntry(question: fallbackToLive ? "【实时文字 · 未定稿】" + question : question, answer: result.text, isLive: live, citations: cited, contextWasTruncated: result.contextWasTruncated)) }
                try self.update(record)
                self.assistantStatus = !result.unsupportedCitationIDs.isEmpty ? "已保存 · 部分引用编号无有效来源，请核对" : result.contextWasTruncated ? "已保存 · 仅基于选取片段，未覆盖整场" : "已保存 · 请核对 AI 内容与出处"
                self.assistantDraft = ""
            } catch is CancellationError { if self.assistantGeneration == generation { self.assistantStatus = "已取消，已有内容保留" } }
            catch { if self.assistantGeneration == generation { self.error = error.localizedDescription; self.assistantStatus = "本地助手生成失败" } }
            if self.assistantGeneration == generation { self.assistantAutomatic = false; self.assistantBusy = false; self.assistantGeneration = nil; self.assistantTask = nil }
        }
    }

    func renameSpeaker(_ id: String, name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, var current else { return }
        saveEdits(); current = self.current ?? current
        current.speakerNames[current.canonicalSpeaker(id)] = name
        do { try update(current) } catch { self.error = error.localizedDescription }
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
    func editTranscriptParagraph(_ id: UUID, text: String) {
        guard !locked, var current, current.hasCurrentParagraphs,
              let index = current.transcriptParagraphs.firstIndex(where: { $0.id == id }) else { return }
        current.transcriptParagraphs[index].text = text
        current.text = current.paragraphText
        do { try update(current); self.text = current.text } catch { self.error = error.localizedDescription }
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
        !recording && !preparing && current?.hasCurrentParagraphs == true
            && current.flatMap { TranscriptPlaybackRange(paragraph: paragraph, record: $0) } != nil
    }
    func playTranscriptParagraph(_ paragraph: TranscriptParagraph) {
        guard canPlayTranscriptParagraph(paragraph), let record = current,
              let latest = record.transcriptParagraphs.first(where: { $0.id == paragraph.id }),
              let file = latest.audioFile, let index = record.audioFiles.firstIndex(of: file) else { return }
        selectPlaybackSegment(index)
        guard let audio else { return }
        do {
            let prepared = try AVAudioPlayer(contentsOf: audio)
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
        return (cleanTitle.isEmpty || current.title == cleanTitle) && current.text == text && current.notes == notes
            && (current.summary ?? "") == summary && current.enhancedNotes == enhancedNotes
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
        cancelAssistant()
        if let pending { await pending.value }
        if let continuousWorker { await continuousWorker.value }
        guard !busy, continuousWorker == nil else { return false }
        stopPlayback()
        return saveBeforeQuit()
    }

    func prepareToQuit() -> Bool {
        if quitting { return false }
        let activity = QuitActivity.resolve(recording: recording, preparing: preparing, transcribing: busy || continuousWorker != nil, recovering: recoveryBusy,
            externalTask: syncing || dingTalkAccount.busy || notionAccount.busy || feishuAccount.busy || assistantBusy)
        if activity == .idle { stopPlayback(); return saveBeforeQuit() }
        let alert = NSAlert()
        alert.messageText = activity.title
        alert.informativeText = activity.detail
        alert.addButton(withTitle: activity.action ?? "返回应用")
        if activity.action != nil { alert.addButton(withTitle: "返回应用") }
        guard alert.runModal() == .alertFirstButtonReturn, activity.action != nil else { return false }
        switch activity {
        case .recording:
            quitting = true
            finishRecording(finalize: false, onSaved: { NSApp.terminate(nil) })
        case .transcribing:
            Task { if await cancelTranscriptionAndSaveForQuit() { NSApp.terminate(nil) } }
        default: break
        }
        return false
    }
}
