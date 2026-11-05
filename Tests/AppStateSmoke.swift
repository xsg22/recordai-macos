import Foundation
import AVFoundation

@main
struct AppStateSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("cohear-state-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = MeetingRecord(title: "中文会议", text: "旧文本", notes: "保留重要决定", status: .completed)
        original.summary = "历史摘要"
        original.enhancedNotes = "历史增强笔记"
        original.actionItems = [MeetingActionItem(title: "历史行动项")]
        try JSONEncoder().encode([original]).write(to: root.appendingPathComponent("history.json"))
        let state = AppState(storageURL: root, connectionNamespace: "smoke-" + UUID().uuidString)
        state.select(original.id)
        verifyExecutionTrace(state)
        try verifyAgentOnboarding(root.appendingPathComponent("Onboarding"))
        state.title = ""
        state.saveEdits()
        let library = try MeetingLibrary(root: root)
        let savedNotes = try library.load(original.id).notes
        precondition(savedNotes == "保留重要决定")
        var updated = try library.load(original.id)
        updated.text = "新的中文识别结果"
        _ = try library.save(updated)
        state.history = try library.list()
        state.select(original.id, saveCurrent: false)
        precondition(state.text == "新的中文识别结果")
        state.title = "星标前未保存的标题"
        state.toggleStar()
        let starred = try library.load(original.id)
        precondition(starred.isStarred && starred.title == state.title)
        precondition(starred.notes == original.notes && starred.summary == original.summary)
        precondition(starred.enhancedNotes == original.enhancedNotes && starred.actionItems == original.actionItems)
        state.toggleStar()
        let unstarred = try library.load(original.id)
        precondition(!unstarred.isStarred)
        let attachmentSource = root.appendingPathComponent("notes.txt")
        try Data("附件内容".utf8).write(to: attachmentSource)
        state.title = "添加附件前的未保存标题"
        precondition(state.addAttachment(attachmentSource))
        let attachmentSaved = try library.load(original.id)
        precondition(attachmentSaved.attachments.count == 1 && attachmentSaved.title == state.title)
        precondition(attachmentSaved.notes == original.notes && attachmentSaved.summary == original.summary)
        precondition(attachmentSaved.enhancedNotes == original.enhancedNotes && attachmentSaved.actionItems == original.actionItems)
        precondition(state.removeAttachment(attachmentSaved.attachments[0].id))
        precondition(FileManager.default.fileExists(atPath: attachmentSource.path))
        let savedText = try library.load(original.id).text
        precondition(savedText == "新的中文识别结果")
        state.search = "重要决定"
        precondition(state.filteredHistory.isEmpty) // 录音搜索不再隐式匹配历史笔记。
        state.search = "新的中文"
        precondition(state.filteredHistory.count == 1)
        precondition(state.markdown.contains("新的中文识别结果"))
        precondition(!state.markdown.contains("保留重要决定")) // 默认交付仅含原始转录，笔记仍存盘。
        precondition(state.canSyncFinalTranscript)
        for status in [MeetingStatus.recording, .recorded, .transcribing, .interrupted, .failed] {
            state.history[0].status = status
            state.liveText = "这是不能同步的实时预览"
            precondition(!state.canSyncFinalTranscript)
            precondition(!state.markdown.contains("这是不能同步的实时预览"))
        }
        state.history[0].status = .completed
        state.busy = true; precondition(!state.canSyncFinalTranscript); state.busy = false
        state.preparing = true; precondition(!state.canSyncFinalTranscript); state.preparing = false
        state.deleteCurrent()
        precondition(state.deletionRequest?.id == original.id && state.current != nil)
        state.deletionRequest = nil
        precondition(state.history.count == 1, "取消删除不移除记录")
        state.deleteCurrent()
        precondition(state.confirmTrash(original.id))
        precondition(state.history.isEmpty && state.trashedHistory.count == 1 && state.selection == nil)
        precondition(state.restoreTrash(original.id))
        precondition(state.history.count == 1 && state.trashedHistory.isEmpty && state.selection == original.id)
        state.text = " \n"; precondition(!state.canSyncFinalTranscript)
        let retryAudio = root.appendingPathComponent("稍后可用.wav")
        state.useAudio(retryAudio)
        precondition(state.error != nil && state.errorRetry != nil && state.history.count == 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
        do { let writer = try AVAudioFile(forWriting: retryAudio, settings: format.settings); try writer.write(from: buffer) }
        state.retryLastError()
        precondition(state.error == nil && state.errorRetry == nil && state.history.count == 2)
        precondition(state.current?.title == "稍后可用" && FileManager.default.fileExists(atPath: retryAudio.path))
        let importedID = state.selection
        state.reportRecoverableError("本次操作失败") { [weak state] in state?.title = "不应修改另一场会议" }
        state.select(original.id)
        let unchangedTitle = state.title
        state.retryLastError()
        precondition(state.title == unchangedTitle && state.errorRetry == nil && state.error?.contains("录音已改变") == true)
        state.select(importedID)
        print("PASS: AppState旧库迁移/历史内容保全/空标题保护/新转录不被旧编辑覆盖/全文搜索/转录导出，仅临时数据。")
    }

    @MainActor private static func verifyAgentOnboarding(_ root: URL) throws {
        let policy = AgentOnboarding(storage: root)
        var record = MeetingRecord(title: "First transcript", text: "", audioFiles: ["fixture.wav"], status: .recorded)
        precondition(!policy.eligible(record))
        record.previewText = "实时草稿"; precondition(!policy.eligible(record))
        record.status = .completed; record.text = " \n "; precondition(!policy.eligible(record))
        record.text = "已落盘的非空定稿"; precondition(policy.eligible(record))
        record.pendingAudioFiles = ["pending.wav"]; precondition(!policy.eligible(record))
        record.pendingAudioFiles = []; record.status = .failed; precondition(!policy.eligible(record))
        record.status = .completed
        let library = try MeetingLibrary(root: root); _ = try library.save(record)
        let state = AppState(storageURL: root, connectionNamespace: "agent-onboarding-" + UUID().uuidString,
            speechModelStore: ASRModelStore(root: root.appendingPathComponent("AbsentModels")))
        state.select(record.id)
        precondition(state.canShowAgentOnboarding)
        state.busy = true; precondition(!state.canShowAgentOnboarding); state.busy = false
        state.recording = true; precondition(!state.canShowAgentOnboarding); state.recording = false
        state.syncing = true; precondition(!state.canShowAgentOnboarding); state.syncing = false
        state.showModelDownload = true; precondition(!state.canShowAgentOnboarding); state.showModelDownload = false
        let second = MeetingRecord(title: "New recording", audioFiles: ["second.wav"], status: .recorded)
        _ = try library.save(second)
        state.history = try library.list(); state.select(second.id)
        precondition(!state.canShowAgentOnboarding)
        let secondIndex = state.history.firstIndex { $0.id == second.id }!
        state.history[secondIndex].status = .completed; state.text = "Second final transcript"
        precondition(state.saveEdits())
        precondition(state.agentOnboardingRecordingID == second.id && state.canShowAgentOnboarding,
                     "已有旧定稿不能挡住当前新录音完成后的首次引导")
        state.agentOnboardingDidAppear()
        precondition(AgentOnboarding(storage: root).seen && !AgentOnboarding(storage: root).eligible(record))
        precondition(state.canShowAgentOnboarding, "记录已展示不应让引导立即闪退")
        state.dismissAgentOnboarding(); precondition(!state.canShowAgentOnboarding)
        state.saveEdits(); precondition(!state.canShowAgentOnboarding)
        let reopened = AppState(storageURL: root, connectionNamespace: "agent-reopen-" + UUID().uuidString)
        reopened.select(record.id); precondition(!reopened.canShowAgentOnboarding)
        let guide = try String(contentsOf: root.appendingPathComponent("AgentData/SETUP.md"), encoding: .utf8)
        precondition(guide.contains("setup --json") && guide.contains("get_agent_setup"))
        let publicRoot = root.appendingPathComponent("AgentData")
        let start = try TalkTuckControlQueue.enqueue(action: "start_recording", root: publicRoot)
        state.processTalkTuckCommands()
        let startResult = try JSONSerialization.jsonObject(with: TalkTuckControlQueue.result(start.id, root: publicRoot)) as! [String: String]
        precondition(startResult["status"] == "rejected" && !state.recording && !state.preparing, "缺模型不得把启动回执记为成功")
        let stale = TalkTuckControlCommand(id: UUID(), action: "pause_recording", createdAt: Date().addingTimeInterval(-60))
        let staleURL = publicRoot.appendingPathComponent("Control/commands/\(stale.id.uuidString).json")
        try AgentCodec.encoder().encode(stale).write(to: staleURL)
        state.processTalkTuckCommands()
        let staleResult = try JSONSerialization.jsonObject(with: TalkTuckControlQueue.result(stale.id, root: publicRoot)) as! [String: String]
        precondition(staleResult["status"] == "rejected" && staleResult["result"]?.contains("过期") == true)
        precondition(TalkTuckControlQueue.pending(root: publicRoot).isEmpty)
        print("PASS: 首次非空定稿引导、失败与草稿排除、忙碌不打扰、展示持久化、稍后/重启不重弹、本地安装说明。")
    }

    @MainActor private static func verifyExecutionTrace(_ state: AppState) {
        let history = state.history
        let phase = state.transcriptPhase
        defer {
            state.history = history; state.transcriptPhase = phase
            state.busy = false; state.recording = false; state.paused = false
        }
        func stage(_ title: String) -> (String, String, String) {
            TalkTuckExecutionView(state: state).stages.first { $0.0 == title }!
        }
        state.history[0].status = .failed
        state.transcriptPhase = .failed
        precondition(!state.current!.text.isEmpty)
        precondition(stage("最终转录").1 == "失败", "旧正文不能掩盖本次转录失败")
        precondition(stage("最终转录").2.contains("已有正文已保留"))
        precondition(TalkTuckExecutionView(state: state).sessionStatus == "待重试")
        state.transcriptPhase = .idle
        precondition(stage("最终转录").1 == "失败", "重新选中失败记录后仍须显示失败")
        state.history[0].status = .completed
        state.busy = true; state.transcriptPhase = .recognizing
        precondition(stage("最终转录").1 == "处理中" && stage("发言人 / 对齐").1 == "等待")
        state.transcriptPhase = .diarizing
        precondition(stage("最终转录").1 == "已保存" && stage("发言人 / 对齐").1 == "处理中")
        state.busy = false; state.transcriptPhase = .completed
        for (status, title) in [(SpeakerAnalysisStatus.completed, "已完成"), (.partial, "部分完成"), (.failed, "待重试"), (.cancelled, "已取消")] {
            state.history[0].speakerAnalysisStatus = status
            state.history[0].speakerAnalysisMessage = "正文已保存，分析结果需要核对。"
            precondition(stage("发言人 / 对齐").1 == title)
            precondition(stage("发言人 / 对齐").2 == state.current?.speakerAnalysisMessage)
            precondition(stage("最终转录").1 == "已保存", "分析失败或取消不应丢失已保存的转录")
        }
        state.recording = true; state.paused = true
        precondition(stage("音频采集").1 == "已暂停" && stage("实时 ASR").1 == "已暂停")
        print("PASS: 执行追踪失败不被旧正文掩盖、重开失败记录、识别与分人阶段分离、分析结果与暂停状态。无硬件采集。")
    }

    static func librarySummary(_ root: URL, _ id: UUID) throws -> String {
        try MeetingLibrary(root: root).load(id).summary ?? ""
    }
}
