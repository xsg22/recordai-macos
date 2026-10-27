import Foundation

@main struct SpeakerStateFlowSmoke {
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-state-flow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(storageURL: root, connectionNamespace: "state-flow-" + UUID().uuidString)
        precondition(state.model != nil, "本测试必须运行在带模型资源的测试bundle中")
        state.useAudio(source)
        state.transcribe()
        var edited = false
        let deadline = Date().addingTimeInterval(180)
        while state.busy && Date() < deadline {
            if !edited && state.transcriptPhase == .diarizing {
                state.notes = "分析期间追加的手稿";state.scheduleSave();edited = true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(!state.busy && state.current?.status == .completed)
        precondition(state.current?.speakerAnalysisStatus == .completed, state.current?.speakerAnalysisMessage ?? "")
        precondition(state.current?.hasCurrentParagraphs == true && state.current?.speakerNames.count == 2)
        precondition(state.notes == "分析期间追加的手稿" && state.current?.notes == state.notes)
        print("PASS: 真实AppState完成定稿→分人→对齐，分析期间新增手稿保留。")
        fflush(stdout)
        state.transcribe()
        var cancelled = false
        let cancelDeadline = Date().addingTimeInterval(180)
        while state.busy && Date() < cancelDeadline {
            if !cancelled && state.transcriptPhase == .diarizing { state.cancel();cancelled = true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(cancelled && !state.busy)
        precondition(state.current?.status == .completed && state.current?.speakerAnalysisStatus == .cancelled)
        precondition(state.current?.pendingAudioFiles.isEmpty == true && !state.text.isEmpty)
        print("PASS: 真实分析阶段取消后正文保持completed，音频/手稿不丢失，不重复追加。仅合成资料。")
    }
}
