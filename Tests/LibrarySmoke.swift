import Foundation

@main
struct LibrarySmoke {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("CoHear-Library-Test-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let oldID = UUID()
        let legacy = """
        [{"id":"\(oldID)","title":"旧会议","created":0,"text":"中文","subtitles":"字幕","language":"zh","seconds":12}]
        """
        let ambiguous = Data("{\"id\":\"\(oldID)\",\"title\":\"旧会议\",\"created\":0,\"userId\":\"\(UUID().uuidString)\"}".utf8)
        expectFailure("旧账号归属不猜测") { _ = try JSONDecoder().decode(MeetingRecord.self, from: ambiguous) }
        let unsupported = Data("{\"identitySchemaVersion\":1,\"id\":\"\(oldID)\",\"title\":\"旧会议\",\"created\":0}".utf8)
        expectFailure("未知身份版本不回退") { _ = try JSONDecoder().decode(MeetingRecord.self, from: unsupported) }
        let history = temp.appendingPathComponent("history.json")
        try Data(legacy.utf8).write(to: history)
        let library = try MeetingLibrary(root: temp)
        check(try library.list().count == 1, "历史迁移")
        check(try library.load(oldID).duration == 0, "旧耗时不冒充会议时长")
        check(try !library.load(oldID).isStarred, "旧记录默认无星标")
        var starred = try library.load(oldID)
        starred.isStarred = true
        starred.actionItems = [MeetingActionItem(title: "确认负责人", isDone: true, assignee: "产品组", dueDate: Date(timeIntervalSince1970: 1234))]
        _ = try library.save(starred)
        check(try MeetingLibrary(root: temp).load(oldID).isStarred, "星标持久化")
        check(try MeetingLibrary(root: temp).load(oldID).actionItems.first?.isDone == true, "行动项持久化")
        check(try MeetingLibrary(root: temp).load(oldID).actionItems.first?.assignee == "产品组", "行动项负责人持久化")
        check(try MeetingLibrary(root: temp).load(oldID).actionItems.first?.dueDate == Date(timeIntervalSince1970: 1234), "截止日期持久化")
        let oldAction = Data("{\"id\":\"\(UUID().uuidString)\",\"title\":\"旧行动项\",\"isDone\":false}".utf8)
        let decodedAction = try JSONDecoder().decode(MeetingActionItem.self, from: oldAction)
        check(decodedAction.assignee.isEmpty && decodedAction.dueDate == nil, "旧行动项兼容")
        check(try Data(contentsOf: temp.appendingPathComponent("history-v0.1-backup.json")) == Data(legacy.utf8), "完整备份")
        check(try Data(contentsOf: history) == Data(legacy.utf8), "旧原件保留")
        _ = try library.rename(oldID, title: "已修改")
        check(try MeetingLibrary(root: temp).load(oldID).title == "已修改", "迁移幂等")
        var meeting = MeetingRecord(title: "中文会议", text: "讨论方案", duration: 123, notes: "确认负责人", summary: "离线使用", status: .recorded)
        let source = temp.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let imported = try library.importAudio(source, into: &meeting)
        check(fm.fileExists(atPath: source.path) && imported != source, "源文件保留")
        check(try Data(contentsOf: imported) == Data(contentsOf: source), "音频复制完整")
        check(try library.audioURLs(for: meeting) == [imported], "定位托管音频")
        let attachmentSource = temp.appendingPathComponent("requirements.txt")
        try Data("本地附件".utf8).write(to: attachmentSource)
        let attachment = try library.importAttachment(attachmentSource, into: &meeting)
        let attachmentURL = try library.attachmentURL(attachment, meeting: meeting.id)
        check(try Data(contentsOf: attachmentURL) == Data(contentsOf: attachmentSource), "附件保存副本")
        check(try library.load(meeting.id).attachments.first?.id == attachment.id, "附件元数据持久化")
        var invalidAttachment = MeetingAttachment(filename: "../../secret", displayName: "unsafe", bytes: 0)
        expectFailure("附件跨目录路径拒绝") { _ = try library.attachmentURL(invalidAttachment, meeting: meeting.id) }
        invalidAttachment.filename = "escape.txt"
        try fm.createSymbolicLink(at: attachmentURL.deletingLastPathComponent().appendingPathComponent("escape.txt"), withDestinationURL: attachmentSource)
        expectFailure("附件符号链接拒绝") { _ = try library.attachmentURL(invalidAttachment, meeting: meeting.id) }
        var invalidAttachmentRecord = meeting
        invalidAttachmentRecord.title = ""
        let beforeFailedImport = try fm.contentsOfDirectory(atPath: attachmentURL.deletingLastPathComponent().path).sorted()
        expectFailure("附件保存失败回滚副本") { _ = try library.importAttachment(attachmentSource, into: &invalidAttachmentRecord) }
        check(try fm.contentsOfDirectory(atPath: attachmentURL.deletingLastPathComponent().path).sorted() == beforeFailedImport, "失败不遗留附件副本")
        check(try library.list(query: "离线").isEmpty, "历史摘要不参与录音搜索")
        check(try library.list(query: "负责人").isEmpty, "历史笔记不参与录音搜索")
        meeting.text = "编辑后文本"
        meeting.status = .transcribing
        _ = try library.save(meeting)
        let recovered = try MeetingLibrary(root: temp)
        let restored = try recovered.load(meeting.id)
        check(restored.status == .interrupted && restored.recoveryMessage != nil, "中断转录可恢复")
        check(restored.text == "编辑后文本" && fm.fileExists(atPath: imported.path), "保留文本音频")
        check(try recovered.recoverInterrupted().isEmpty, "恢复幂等")
        let markdown = library.markdown(for: restored)
        check(markdown.contains("123 秒") && !markdown.contains("## 会议摘要") && markdown.contains("编辑后文本"), "Markdown内容完整")
        let output = temp.appendingPathComponent("export.md")
        try library.exportMarkdown(restored, to: output)
        check(try String(contentsOf: output, encoding: .utf8) == markdown, "Markdown导出")
        try library.trash(meeting.id)
        check(try !library.list().contains { $0.id == meeting.id }, "回收站不进入活跃库")
        check(try library.listTrashed().contains { $0.id == meeting.id }, "回收站列出录音")
        check(fm.fileExists(atPath: source.path), "回收站保留导入源文件")
        check(!fm.fileExists(atPath: imported.path), "活跃音轨随会议移入回收站")
        _ = try library.save(restored)
        expectFailure("恢复不得覆盖活跃同名记录") { _ = try library.restoreTrashed(meeting.id) }
        check(try library.listTrashed().contains { $0.id == meeting.id }, "恢复冲突保留回收站原件")
        try fm.removeItem(at: library.directory(for: meeting.id))
        let restoredTrash = try library.restoreTrashed(meeting.id)
        check(restoredTrash.text == restored.text && fm.fileExists(atPath: imported.path), "恢复保全正文与托管音频")
        check(try Data(contentsOf: library.attachmentURL(attachment, meeting: meeting.id)) == Data("本地附件".utf8), "回收站恢复附件")
        check(try Data(contentsOf: imported) == Data("audio".utf8), "恢复音频内容完整")
        expectFailure("重复恢复不覆盖已恢复记录") { _ = try library.restoreTrashed(meeting.id) }
        var attachmentRecord = restoredTrash
        try library.removeAttachment(attachment.id, from: &attachmentRecord)
        check(attachmentRecord.attachments.isEmpty && fm.fileExists(atPath: attachmentSource.path), "移除附件不删除源文件")
        var recording = MeetingRecord(title: "未完成录音", status: .recorded)
        let recordingURL = try library.recordingURL(for: &recording)
        check(recording.status == .recording && recordingURL.pathExtension == "m4a", "录音前落盘")
        check(try MeetingLibrary(root: temp).load(recording.id).status == .interrupted, "中断录音可发现")
        var unsafe = meeting
        unsafe.audioFiles = ["../../secret"]
        expectFailure("跨目录路径") { _ = try library.save(unsafe) }
        expectFailure("空标题") { _ = try library.rename(oldID, title: "  ") }
        let outside = temp.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = library.directory(for: meeting.id).appendingPathComponent("Audio/escape.wav")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("audio.wav"))
        unsafe.audioFiles = ["escape.wav"]
        expectFailure("符号链接逃逸") { _ = try library.audioURLs(for: unsafe) }
        let broken = library.directory(for: UUID())
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: broken.appendingPathComponent("meeting.json"))
        check(try library.list().count == 3, "单条损坏不影响其他会议")
        check(library.warnings.count == 1, "损坏告警")
        let invalidRoot = temp.appendingPathComponent("InvalidLegacy")
        try fm.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        let invalid = invalidRoot.appendingPathComponent("history.json")
        try Data("broken".utf8).write(to: invalid)
        expectFailure("损坏历史不静默跳过") { _ = try MeetingLibrary(root: invalidRoot) }
        check(try String(contentsOf: invalid, encoding: .utf8) == "broken", "损坏原件保留")
        print("MeetingLibrary smoke passed（仅临时测试数据）")
    }
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func expectFailure(_ message: String, operation: () throws -> Void) {
        do { try operation(); fatalError(message) } catch { }
    }
}
