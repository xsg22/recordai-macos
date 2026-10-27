import Foundation
@main struct MeetingWorkspacePersistenceSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(title: "合成会议", text: "最终正文", notes: "原始手稿", previewText: "实时暂定结果")
        record.enhancedNotes = "AI整理，保留原稿"
        record.summary = "片段摘要"
        record.summaryContextWasTruncated = true
        record.summaryCitations = [MeetingCitation(id: "T001", kind: "transcript", text: "最终正文")]
        record.assistantEntries = [MeetingAssistantEntry(question: "谁负责？", answer: "来源未说明 [T001]", isLive: true, citations: record.summaryCitations)]
        _ = try library.save(record)
        let loaded = try library.load(record.id)
        precondition(loaded.previewText == "实时暂定结果" && loaded.text == "最终正文")
        precondition(loaded.notes == "原始手稿" && loaded.enhancedNotes == "AI整理，保留原稿")
        precondition(loaded.assistantEntries.count == 1 && loaded.assistantEntries[0].isLive)
        precondition(loaded.summaryContextWasTruncated && loaded.summaryCitations.count == 1)
        precondition(!library.markdown(for: loaded).contains("片段摘要")) // 历史生成内容保留但不默认交付。
        let data = try JSONEncoder().encode(record)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for field in ["enhancedNotes", "assistantEntries", "summaryCitations", "enhancedNotesCitations", "summaryContextWasTruncated", "enhancedNotesContextWasTruncated"] { legacy.removeValue(forKey: field) }
        let old = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.enhancedNotes.isEmpty && old.assistantEntries.isEmpty && !old.summaryContextWasTruncated)
        let now = Date(timeIntervalSince1970: 100)
        func gate(_ age: Double = 15, enabled: Bool = true, recording: Bool = true, paused: Bool = false,
                  preparing: Bool = false, busy: Bool = false, ready: Bool = true, text: String = "新增问题？") -> Bool {
            LiveQASchedule.shouldRun(now: now, lastRun: now.addingTimeInterval(-age), enabled: enabled,
                                    recording: recording, paused: paused, preparing: preparing,
                                    assistantBusy: busy, modelReady: ready, pendingText: text)
        }
        precondition(gate() && !gate(14.99))
        precondition(!gate(enabled: false) && !gate(recording: false) && !gate(paused: true))
        precondition(!gate(preparing: true) && !gate(busy: true) && !gate(ready: false) && !gate(text: " \n"))
        print("PASS: final/live separation, handwritten preservation, AI provenance persistence, legacy decode, 15s Live Q&A gates")
    }
}
