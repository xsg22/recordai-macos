import Foundation
import AVFoundation

@main
struct AppStateSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-state-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = MeetingRecord(title: "中文会议", text: "旧文本", status: .completed)
        try JSONEncoder().encode([original]).write(to: root.appendingPathComponent("history.json"))
        let state = AppState(storageURL: root, connectionNamespace: "smoke-" + UUID().uuidString)
        state.select(original.id)
        verifyExecutionTrace(state)
        precondition(!state.updateSummary("错误会议", meetingID: UUID()))
        precondition(state.updateSummary("会议摘要\n## 讨论要点\n- 已完成评审\n- 周五交付", meetingID: original.id))
        let outline = MeetingSummaryOutline(state.summary)
        precondition(outline.body == "会议摘要" && outline.points == ["已完成评审", "周五交付"])
        precondition(MeetingSummaryOutline("普通摘要\n- 保留原文").body == "普通摘要\n- 保留原文")
        let persistedSummary = try librarySummary(root, original.id)
        precondition(persistedSummary == state.summary)
        state.notes = "保留重要决定"
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
        state.notes = "星标前未保存的笔记"
        state.toggleStar()
        let starred = try library.load(original.id)
        precondition(starred.isStarred && starred.notes == "星标前未保存的笔记")
        state.toggleStar()
        let unstarred = try library.load(original.id)
        precondition(!unstarred.isStarred)
        precondition(state.updateActionItems { $0.append(MeetingActionItem(title: "安排评审")) })
        let actionID = try library.load(original.id).actionItems[0].id
        precondition(state.updateActionItems { items in items[0].isDone = true })
        let completedAction = try library.load(original.id).actionItems[0]
        precondition(completedAction.id == actionID && completedAction.isDone)
        precondition(state.updateActionItems { $0.removeAll { $0.id == actionID } })
        let emptyActions = try library.load(original.id).actionItems
        precondition(emptyActions.isEmpty)
        let attachmentSource = root.appendingPathComponent("notes.txt")
        try Data("附件内容".utf8).write(to: attachmentSource)
        state.notes = "添加附件前的未保存笔记"
        precondition(state.addAttachment(attachmentSource))
        let attachmentSaved = try library.load(original.id)
        precondition(attachmentSaved.attachments.count == 1 && attachmentSaved.notes == state.notes)
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
        precondition(state.title == unchangedTitle && state.errorRetry == nil && state.error?.contains("会议已改变") == true)
        state.select(importedID)
        print("PASS: AppState旧库迁移/笔记保存/空标题保护/新转录不被旧编辑覆盖/全文搜索/会议导出，仅临时数据。")
    }

    @MainActor private static func verifyExecutionTrace(_ state: AppState) {
        let history = state.history
        let phase = state.transcriptPhase
        defer {
            state.history = history; state.transcriptPhase = phase
            state.busy = false; state.recording = false; state.paused = false
        }
        func stage(_ title: String) -> (String, String, String) {
            RecordAIExecutionView(state: state).stages.first { $0.0 == title }!
        }
        state.history[0].status = .failed
        state.transcriptPhase = .failed
        precondition(!state.current!.text.isEmpty)
        precondition(stage("最终转录").1 == "失败", "旧正文不能掩盖本次转录失败")
        precondition(stage("最终转录").2.contains("已有正文已保留"))
        precondition(RecordAIExecutionView(state: state).sessionStatus == "待重试")
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
