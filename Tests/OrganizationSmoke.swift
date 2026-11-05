import Foundation
import CryptoKit

@main struct OrganizationSmoke {
    @MainActor static func main() throws {
        try unselectedCardActions()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("talktuck-organization-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(title: "录音资料", text: "测试正文", duration: 20, notes: "保留笔记", summary: "保留摘要")
        let source = root.appendingPathComponent("source.wav")
        try Data("unchanged-audio".utf8).write(to: source)
        _ = try library.importAudio(source, into: &record)
        record.audioDurations[record.audioFiles[0]] = 20
        _ = try library.save(record)
        let other = MeetingRecord(title: "第二条", text: "其他文字")
        _ = try library.save(other)
        let initial = try AgentReadStore(root: root.appendingPathComponent("AgentData")).read(record.id)
        let snapshotURL = root.appendingPathComponent("AgentData/recordings/\(record.id.uuidString)/record.json")
        var legacySnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any]
        var legacyOrganization = legacySnapshot["organization"] as! [String: Any]
        legacyOrganization["tags"] = [["id": UUID().uuidString, "name": "retired"]]
        legacyOrganization["bookmarks"] = [["id": UUID().uuidString, "title": "retired", "audioPart": 1, "localTime": 5.25]]
        legacySnapshot["organization"] = legacyOrganization
        try JSONSerialization.data(withJSONObject: legacySnapshot).write(to: snapshotURL)
        library.republishAgentData()
        let cleanedSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any]
        precondition((cleanedSnapshot["organization"] as! [String: Any])["tags"] == nil)
        precondition((cleanedSnapshot["organization"] as! [String: Any])["bookmarks"] == nil)
        let cleaned = try AgentReadStore(root: root.appendingPathComponent("AgentData")).read(record.id)
        precondition(cleaned.revision == initial.revision && cleaned.contentDigest == initial.contentDigest)
        let recordURL = library.directory(for: record.id).appendingPathComponent("meeting.json")
        var legacyRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
        legacyRecord["bookmarks"] = [["id": UUID().uuidString, "title": "retired", "audioFile": record.audioFiles[0], "localTime": 5.25]]
        try JSONSerialization.data(withJSONObject: legacyRecord).write(to: recordURL)
        let loadedLegacy = try library.load(record.id)
        precondition(loadedLegacy.text == record.text && loadedLegacy.audioFiles == record.audioFiles)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loadedLegacy)) as! [String: Any]
        precondition(reencoded["bookmarks"] == nil)
        let oldCatalog = Data("{\"groups\":[],\"tags\":[{\"id\":\"\(UUID())\",\"name\":\"retired\"}]}".utf8)
        let decoded = try JSONDecoder().decode(LibraryOrganization.self, from: oldCatalog)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        precondition(encoded["tags"] == nil && decoded.groups.isEmpty)
        let state = AppState(storageURL: root, connectionNamespace: "organization-test-" + UUID().uuidString)
        state.select(record.id)
        precondition(state.saveCollection(name: " 工作 "))
        precondition(!state.saveCollection(name: "工作"))
        state.error = nil
        let group = state.organization.groups[0]
        precondition(state.setGroup(group.id, recordIDs: [record.id, other.id]))
        precondition(state.setGroup(nil, recordIDs: [other.id]))
        state.groupFilter = group.id.uuidString
        precondition(state.filteredHistory.map(\.id) == [record.id], "分组筛选只匹配指定分组")
        precondition(state.setGroup(group.id, recordIDs: [other.id]))
        precondition(!state.saveCollection(name: "工作", inlineErrors: true))
        precondition(state.error == nil && state.organizationIssue != nil)
        state.search = "测试正文"
        precondition(state.filteredHistory.count == 1, "正文仍可检索")
        let published = try AgentReadStore(root: root.appendingPathComponent("AgentData")).read(record.id)
        precondition(published.contentDigest == initial.contentDigest && published.revision == initial.revision, "整理不改变转录版本")
        precondition((published.organization?.revision ?? 0) > (initial.organization?.revision ?? 0))
        precondition(published.matches(query: "测试正文", groupID: group.id))
        precondition(!published.matches(ungrouped: true))
        let restored = AppState(storageURL: root, connectionNamespace: "organization-reopen-" + UUID().uuidString)
        restored.select(record.id)
        precondition(restored.organization.groups.first?.id == group.id)
        precondition(restored.current?.notes == "保留笔记" && restored.current?.summary == "保留摘要")
        precondition(restored.saveCollection(name: "项目", id: group.id))
        let renamed = try AgentReadStore(root: root.appendingPathComponent("AgentData")).read(record.id)
        precondition(renamed.organization?.group?.name == "项目" && renamed.contentDigest == initial.contentDigest)
        if let fixture = ProcessInfo.processInfo.environment["TALKTUCK_TEST_AGENT_OUT"] {
            let target = URL(fileURLWithPath: fixture)
            try fm.copyItem(at: root.appendingPathComponent("AgentData"), to: target)
            let fixtureIDs = ["recordingID": record.id.uuidString, "otherID": other.id.uuidString, "groupID": group.id.uuidString]
            try JSONSerialization.data(withJSONObject: fixtureIDs).write(to: target.appendingPathComponent("fixture.json"))
        }
        // A snapshot written before event-log failure must later regain its metadata event.
        let eventsURL = root.appendingPathComponent("AgentData/events.json")
        let eventsBackup = try Data(contentsOf: eventsURL)
        try fm.removeItem(at: eventsURL); try fm.createDirectory(at: eventsURL, withIntermediateDirectories: true)
        precondition(restored.setGroup(nil, recordIDs: [record.id]))
        try fm.removeItem(at: eventsURL); try eventsBackup.write(to: eventsURL)
        library.republishAgentData()
        let repairedStore = AgentReadStore(root: root.appendingPathComponent("AgentData"))
        let repaired = try repairedStore.read(record.id)
        let changes = try repairedStore.changes(since: 0)
        precondition(changes.events.contains { $0.id == record.id && $0.kind == "metadata" && $0.metadataRevision == repaired.organization?.revision })
        precondition(restored.setGroup(group.id, recordIDs: [record.id]))
        try library.trash(other.id)
        precondition(restored.removeCollection(group.id))
        let ungrouped = try library.load(record.id)
        let trash = try library.listTrashed().first { $0.id == other.id }
        precondition(ungrouped.groupID == nil && trash?.groupID == nil)
        let returned = try library.restoreTrashed(other.id)
        precondition(returned.groupID == nil, "恢复不会复活已删除分类")
        let audioBytes = try Data(contentsOf: library.audioURLs(for: ungrouped)[0])
        precondition(audioBytes == Data("unchanged-audio".utf8))
        precondition(ungrouped.text == "测试正文")
        let beforeFailure = restored.organization
        try fm.removeItem(at: root.appendingPathComponent("organization.json"))
        try fm.createDirectory(at: root.appendingPathComponent("organization.json"), withIntermediateDirectories: true)
        precondition(!restored.saveCollection(name: "失败分类"))
        precondition(restored.organization == beforeFailure, "写盘失败不发布未保存分类")
        library.republishAgentData()
        let preservedPublished = try AgentReadStore(root: root.appendingPathComponent("AgentData")).list()
        precondition(!preservedPublished.isEmpty && library.publicationError != nil, "损坏分类索引不能导致已发布资料被清空")

        // Real transcript replay is read-only; never update the personal library or microphone.
        if CommandLine.arguments.count > 1 {
            let original = try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let groups = TranscriptReadability.groups(original.transcriptParagraphs)
            precondition(groups.flatMap(\.paragraphs) == original.transcriptParagraphs, "阅读分组保全所有 ID、标签和时间戳")
            precondition(groups.map { $0.combined.separator + $0.combined.text }.joined() == original.text)
            let before = original.transcriptParagraphs.filter { $0.text.count == 1 }.count
            let after = groups.filter { $0.combined.text.count == 1 }.count
            precondition(after < before, "真实长录音减少单字阅读段")
            print("REAL_REPLAY original=\(original.transcriptParagraphs.count) reading=\(groups.count) singleBefore=\(before) singleAfter=\(after) unchangedSourceIDs=true")
        }
        let brief = [TranscriptParagraph(text: "嗯。", start: 0, end: 0.3, audioFile: "a", speakerIDs: ["1"]), TranscriptParagraph(text: "好。", start: 0.3, end: 0.6, audioFile: "a", speakerIDs: ["2"])]
        precondition(TranscriptReadability.groups(brief).count == 2, "短答仍是独立语义")
        var english = brief
        english[0].text = "OK."; english[1].text = "Yes."
        precondition(TranscriptReadability.groups(english).count == 2, "英文短答保留句末边界")
        var edited = brief[0]; edited.text = "页"; edited.previousSpeakerIDs = []
        precondition(TranscriptReadability.groups([edited,brief[1]]).count == 2, "人工归属不能被合并掩盖")
        print("PASS: 分组批量整理与筛选、时间点移除兼容与重启、Agent 独立版本、删除分类与回收站恢复、原音保全、写盘失败及阅读分组。")
    }

    @MainActor static func unselectedCardActions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("talktuck-card-actions-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        let selected = MeetingRecord(title: "正在浏览", text: "当前页面的正文", status: .completed)
        _ = try library.save(selected)
        var target = MeetingRecord(title: "右键目标", text: "应被导出的内容", duration: 3, status: .completed)
        target.subtitles = "1\n00:00:00,000 --> 00:00:03,000\n应被导出的内容\n"
        let source = root.appendingPathComponent("source.wav")
        let bytes = Data("target-audio-preserved".utf8)
        try bytes.write(to: source)
        _ = try library.importAudio(source, into: &target)
        _ = try library.save(target)
        let state = AppState(storageURL: root, connectionNamespace: "card-actions-" + UUID().uuidString)
        state.select(selected.id)
        state.title = "当前页面已改名"
        precondition(state.saveCollection(name: "学习"))
        let group = state.organization.groups[0]
        precondition(state.setGroup(group.id, recordIDs: [target.id]))
        precondition(state.selection == selected.id && state.current?.groupID == nil)
        precondition(state.organization.group(state.history.first { $0.id == target.id }?.groupID)?.name == "学习")
        for kind in ["文本", "Markdown", "JSON", "字幕"] {
            let document = state.exportDocument(kind: kind, recordingID: target.id)!
            precondition(document.name.hasPrefix(target.title + "."))
            precondition(document.content.contains(target.text) && !document.content.contains(selected.text))
            if kind == "字幕" { precondition(document.content == target.subtitles) }
        }
        precondition((try? library.load(selected.id).title) == "当前页面已改名", "导出另一条前保存当前编辑")
        precondition(state.exportDocument(kind: "文本", recordingID: UUID()) == nil, "失效目标不能回退为当前录音")
        let destination = try state.exportAudio(to: root, recordingID: target.id)
        let exports = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        precondition(exports.count == 1)
        precondition((try? Data(contentsOf: exports[0])) == bytes, "导出明确目标的原音")
        state.toggleStar(recordingID: target.id)
        precondition(state.current?.isStarred == false && state.history.first { $0.id == target.id }?.isStarred == true)
        state.recording = true
        state.requestTrash(target.id)
        precondition(state.deletionRequest == nil && !state.setGroup(nil, recordIDs: [target.id]))
        precondition(state.exportDocument(kind: "文本", recordingID: target.id) == nil)
        state.recording = false
        state.requestTrash(target.id)
        precondition(state.deletionRequest?.id == target.id && state.selection == selected.id)
        precondition(!state.confirmTrash(selected.id), "确认不能删除其他录音")
        state.deletionRequest = nil
        precondition(state.history.contains { $0.id == target.id }, "取消不删除")
        state.requestTrash(target.id)
        precondition(state.confirmTrash(target.id))
        precondition(state.selection == selected.id && state.text == selected.text && state.title == "当前页面已改名")
        precondition(state.history.count == 1 && state.trashedHistory.first?.id == target.id)
        let restored = try library.restoreTrashed(target.id)
        let restoredAudio = try library.audioURLs(for: restored)
        precondition(restored.groupID == group.id && restored.text == target.text)
        precondition((try? Data(contentsOf: restoredAudio[0])) == bytes)
        precondition((try? Data(contentsOf: source)) == bytes)
        print("PASS: 未选中录音的分组、星标、TXT/Markdown/JSON/SRT及原音导出、删除确认与取消、恢复和录音中写保护；当前页面保持不变。")
    }
}
