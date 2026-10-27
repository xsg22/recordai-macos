import Foundation
@main struct SpeakerEditingSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-edit-speakers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(title: "发言人纠错", text: "你好。\nHello.", notes: "原始手稿", status: .completed)
        record.transcriptParagraphs = [TranscriptParagraph(text: "你好。", start: 1, end: 2, speakerIDs: ["a:0"], localStart: 1),TranscriptParagraph(text: "Hello.", separator: "\n", start: 3, end: 4, speakerIDs: ["a:1"], localStart: 3)]
        record.speakerNames = ["a:0":"发言人 1","a:1":"发言人 2"]
        _ = try library.save(record)
        let state = AppState(storageURL: root, connectionNamespace: "speaker-test-" + UUID().uuidString)
        state.select(record.id)
        state.renameSpeaker("a:0", name: "小王")
        precondition(state.current?.speakerName("a:0") == "小王")
        state.mergeSpeaker("a:1", into: "a:0")
        precondition(state.current?.speakerName("a:1") == "小王")
        state.unmergeSpeaker("a:1")
        precondition(state.current?.speakerName("a:1") == "发言人 2")
        let originalParagraphs = state.current!.transcriptParagraphs
        state.assignParagraphSpeaker(originalParagraphs[0].id, speakerID: "a:1")
        precondition(state.current?.transcriptParagraphs[0].speakerIDs == ["a:1"])
        precondition(state.current?.transcriptParagraphs[1] == originalParagraphs[1])
        precondition(state.current?.text == record.text && state.current?.speakerAliases.isEmpty == true)
        let assigned = try library.load(record.id)
        precondition(assigned.transcriptParagraphs[0].previousSpeakerIDs == ["a:0"])
        state.undoParagraphSpeaker(originalParagraphs[0].id)
        precondition(state.current?.transcriptParagraphs == originalParagraphs)
        state.assignParagraphSpeaker(originalParagraphs[0].id, speakerID: "unknown")
        precondition(state.current?.transcriptParagraphs == originalParagraphs)
        state.assignParagraphSpeaker(originalParagraphs[0].id, speakerID: nil)
        precondition(state.current?.transcriptParagraphs[0].speakerIDs.isEmpty == true)
        state.undoParagraphSpeaker(originalParagraphs[0].id)
        state.editTranscriptParagraph(record.transcriptParagraphs[1].id, text: "Hello, world.")
        let saved = try library.load(record.id)
        precondition(saved.text == "你好。\nHello, world." && saved.hasCurrentParagraphs)
        precondition(saved.notes == "原始手稿" && saved.transcriptParagraphs[1].localStart == 3)
        state.text = "全文人工修改";state.saveEdits()
        precondition(state.current?.hasCurrentParagraphs == false)
        precondition(!state.markdown.contains("**小王"), "不向修改后的全文强行套用旧标签")
        print("PASS: 改名、合并、恢复独立标签、按段纠错与定位保留、全文修改后不展示过期标签。仅临时会议。")
    }
}
