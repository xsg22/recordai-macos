import Foundation

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
        state.text = " \n"; precondition(!state.canSyncFinalTranscript)
        print("PASS: AppState旧库迁移/笔记保存/空标题保护/新转录不被旧编辑覆盖/全文搜索/会议导出，仅临时数据。")
    }
}
