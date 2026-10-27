import Foundation

@main struct AgentDataSmoke {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cohear-agent-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        let publicRoot = root.appendingPathComponent("AgentData")
        let store = AgentReadStore(root: publicRoot)
        check(try store.list().isEmpty)
        var record = MeetingRecord(title: "测试转录", text: "你好，世界！", notes: "私有历史笔记", summary: "历史总结", previewText: "未定稿")
        record.speakerAnalysisStatus = .processing
        _ = try library.save(record)
        let first = try store.read(record.id)
        precondition(first.livePreview == nil && first.transcriptionReady && !first.ready)
        precondition(first.finalText == record.text && first.legacyContentAvailable && first.revision == 1)
        precondition(!first.markdown.contains("私有历史") && !first.markdown.contains("历史总结"))
        check(try store.read(record.id, includePreview: true).livePreview == "未定稿")
        check(try store.changes(since: 0).events.count == 1)
        _ = try library.save(record)
        check(try store.read(record.id).revision == 1) // 无内容变化不制造新版本。
        record.speakerAnalysisStatus = .completed
        _ = try library.save(record)
        check(try store.read(record.id).ready)
        check(try store.read(record.id).revision == 2)
        check(try store.changes(since: 1).events.count == 1)
        check(try store.changes(since: 999).resyncRequired)
        let before = try Data(contentsOf: library.directory(for: record.id).appendingPathComponent("meeting.json"))
        _ = try store.list(); _ = try store.changes(since: 0)
        check(try Data(contentsOf: library.directory(for: record.id).appendingPathComponent("meeting.json")) == before)
        let secret = String(decoding: try AgentCodec.encoder().encode(first), as: UTF8.self)
        precondition(!secret.contains("历史总结") && !secret.contains("私有历史笔记") && !secret.contains("assistantEntries"))
        // 发布路径损坏不能回滚已保存的会议或音频。
        try fm.removeItem(at: publicRoot)
        try Data("blocked".utf8).write(to: publicRoot)
        record.text = "新正文已保留"
        _ = try library.save(record)
        check(try library.load(record.id).text == "新正文已保留")
        precondition(library.publicationError != nil)
        try fm.removeItem(at: publicRoot)
        library.republishAgentData()
        precondition(library.publicationError == nil)
        check(try store.read(record.id).finalText == "新正文已保留")
        // 音频路径逃逸拒绝。
        var unsafe = record; unsafe.audioFiles = ["../secret"]
        do { _ = try AgentDataPublisher.snapshot(unsafe, libraryRoot: root); fatalError("unsafe accepted") } catch { }
        // 读快照不能通过符号链接逃逸至其他目录。
        let link = publicRoot.appendingPathComponent("recordings/" + UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try store.read(UUID(uuidString: link.lastPathComponent)!); fatalError("symlink accepted") } catch { }
        try fm.removeItem(at: link)
        // 删除原件后显式重建清理已发布副本，并保留删除事件。
        try fm.removeItem(at: library.directory(for: record.id))
        library.republishAgentData()
        check(try store.list().isEmpty)
        check(try store.changes(since: 0).events.last?.kind == "deleted")
        print("PASS: 本机快照白名单、草稿隔离、ready、幂等版本、游标、只读、发布故障保原件、路径安全、删除回收")
    }
}
