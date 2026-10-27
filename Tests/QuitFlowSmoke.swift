import Foundation

@main struct QuitFlowSmoke {
    @MainActor static func main() async throws {
        precondition(QuitActivity.resolve(recording: false, preparing: false, transcribing: false, externalTask: false) == .idle)
        precondition(QuitActivity.resolve(recording: true, preparing: false, transcribing: false, externalTask: false).action == "保存录音并退出")
        precondition(QuitActivity.resolve(recording: false, preparing: false, transcribing: true, externalTask: false).action == "取消转录并退出")
        precondition(QuitActivity.resolve(recording: true, preparing: true, transcribing: false, externalTask: false) == .saving)
        precondition(QuitActivity.resolve(recording: false, preparing: false, transcribing: true, externalTask: true) == .external)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cohear-quit-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        let record = MeetingRecord(title: "退出验收", text: "保留正文")
        _ = try library.save(record)
        let state = AppState(storageURL: root, connectionNamespace: "quit-test-")
        state.select(record.id); state.text = "退出前校正的正文"
        let saved = await state.cancelTranscriptionAndSaveForQuit()
        precondition(saved && !state.quitting)
        let stored = try library.load(record.id)
        precondition(stored.text == "退出前校正的正文")
        // 模拟磁盘无法保存：不能误报可退出。
        try fm.removeItem(at: library.directory(for: record.id))
        try Data("blocked".utf8).write(to: library.directory(for: record.id))
        state.text = "尚未保存的改动"
        let failed = await state.cancelTranscriptionAndSaveForQuit()
        precondition(!failed && state.error != nil && !state.quitting)
        state.preparing = true
        let preparing = await state.cancelTranscriptionAndSaveForQuit()
        precondition(!preparing)
        print("PASS: 退出任务分类/保存与推理动作/保存成功才允许退出/写盘失败保留窗口/准备中不强退。无硬件采集。")
    }
}
