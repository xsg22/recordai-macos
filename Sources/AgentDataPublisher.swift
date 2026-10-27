import Foundation
import CryptoKit

/// 仅App串行调用。任何发布失败均由主库捕获，不影响录音与会议保存。
final class AgentDataPublisher {
    let root: URL
    private let manager = FileManager.default
    private var published: [UUID: (stable: String, full: String, time: Date)] = [:]
    init(libraryRoot: URL) { root = libraryRoot.appendingPathComponent("AgentData") }

    func prepare() throws {
        published.removeAll()
        try manager.createDirectory(at: root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        for (filename, content) in [("index.json", "[]"), ("events.json", "[]"), ("README.md", Self.instructions)] {
            let url = root.appendingPathComponent(filename)
            if !manager.fileExists(atPath: url.path) { try Data(content.utf8).write(to: url, options: .atomic) }
        }
    }
    static func markdown(_ record: MeetingRecord) -> String {
        let title = record.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        var content = "# \(title)\n\n录音时间：\(ISO8601DateFormatter().string(from: record.created))\n\n音频时长：\(Int(max(0, record.duration))) 秒\n\n## 转录正文\n\n"
        if record.hasCurrentParagraphs {
            for row in record.transcriptParagraphs {
                if let time = row.start { content += "**\(record.paragraphSpeaker(row)) · \(Int(max(0, time))) 秒**\n\n" }
                content += row.text + "\n\n"
            }
        } else { content += record.text + "\n" }
        return content
    }
    static func snapshot(_ record: MeetingRecord, libraryRoot: URL, revision: Int = 0) throws -> AgentRecording {
        let fm = FileManager.default
        let base = libraryRoot.appendingPathComponent("Meetings/\(record.id.uuidString)/Audio").resolvingSymlinksInPath().standardizedFileURL
        let audio = try record.audioFiles.enumerated().map { index, file -> AgentAudio in
            guard !file.isEmpty, file != ".", file != "..", !file.contains("/"), !file.contains("\\") else { throw AgentReadError.unsafePath }
            let url = base.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(base.path + "/") else { throw AgentReadError.unsafePath }
            let mime = ["m4a": "audio/mp4", "wav": "audio/wav", "mp3": "audio/mpeg", "aiff": "audio/aiff", "caf": "audio/x-caf"][url.pathExtension.lowercased()] ?? "application/octet-stream"
            return AgentAudio(part: index + 1, path: url.path, mime: mime, duration: record.audioDurations[file], available: fm.fileExists(atPath: url.path))
        }
        let paragraphs = record.hasCurrentParagraphs ? record.transcriptParagraphs.map { row in
            AgentParagraph(id: row.id, text: row.text, separator: row.separator, start: row.start, end: row.end,
                audioPart: row.audioFile.flatMap { record.audioFiles.firstIndex(of: $0).map { $0 + 1 } }, localStart: row.localStart,
                speakers: Array(Set(row.speakerIDs.map { record.speakerName($0) })).sorted(), speakerIDs: Array(Set(row.speakerIDs.map { record.canonicalSpeaker($0) })).sorted())
        } : []
        let transcriptionReady = !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.status == .completed
        return AgentRecording(id: record.id, title: record.title, createdAt: record.created, updatedAt: record.updated, status: record.status.rawValue,
            language: record.language, duration: record.duration, revision: revision, contentDigest: "", transcriptionReady: transcriptionReady,
            speakerAnalysisStatus: record.speakerAnalysisStatus.rawValue, ready: transcriptionReady && record.speakerAnalysisStatus != .processing,
            finalText: record.text, originalSubtitles: record.subtitles, markdown: markdown(record), paragraphs: paragraphs, audioFiles: audio,
            speakers: Array(Set(record.transcriptParagraphs.flatMap(\.speakerIDs).map { record.canonicalSpeaker($0) })).sorted().map { AgentSpeaker(id: $0, name: record.speakerName($0)) },
            transcriptionEngine: record.transcriptionEngine, previewEngine: record.previewEngine,
            captureWarnings: record.captureWarnings.isEmpty ? nil : record.captureWarnings,
            livePreview: record.previewText.isEmpty ? nil : record.previewText,
            legacyContentAvailable: !record.notes.isEmpty || !(record.summary ?? "").isEmpty || !record.enhancedNotes.isEmpty || !record.assistantEntries.isEmpty)
    }
    func publish(_ record: MeetingRecord, libraryRoot: URL) throws {
        let store = AgentReadStore(root: root)
        let old = try? store.read(record.id, includePreview: true)
        var snapshot = try Self.snapshot(record, libraryRoot: libraryRoot)
        // digest不受保存时间影响，避免无内容变化的自动保存产生重复事件。
        var digestSource = snapshot; digestSource.updatedAt = Date(timeIntervalSince1970: 0)
        snapshot.contentDigest = SHA256.hash(data: try AgentCodec.encoder().encode(digestSource)).map { String(format: "%02x", $0) }.joined()
        var stableSource = digestSource; stableSource.livePreview = nil
        let stable = SHA256.hash(data: try AgentCodec.encoder().encode(stableSource)).map { String(format: "%02x", $0) }.joined()
        if let last = published[record.id] {
            if last.full == snapshot.contentDigest { return }
            // 高频partial只发布至多每2秒一份；状态/正文/分人变化始终立即发布。
            if last.stable == stable && Date().timeIntervalSince(last.time) < 2 { return }
        }
        if old?.contentDigest == snapshot.contentDigest, let old {
            // 上次可能在快照已写入后发布日志失败；重试补齐日志和索引。
            try writeDerived(old)
            try ensureChange(id: old.id, revision: old.revision)
            try refreshIndex(record: old)
            published[record.id] = (stable, snapshot.contentDigest, Date())
            return
        }
        snapshot.revision = (old?.revision ?? 0) + 1
        let directory = root.appendingPathComponent("recordings/\(record.id.uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeDerived(snapshot)
        try AgentCodec.encoder().encode(snapshot).write(to: directory.appendingPathComponent("record.json"), options: .atomic)
        try appendChange(id: record.id, revision: snapshot.revision, kind: "updated")
        try refreshIndex(record: snapshot)
        published[record.id] = (stable, snapshot.contentDigest, Date())
    }
    private func writeDerived(_ snapshot: AgentRecording) throws {
        let directory = root.appendingPathComponent("recordings/\(snapshot.id.uuidString)")
        try Data(snapshot.finalText.utf8).write(to: directory.appendingPathComponent("transcript.txt"), options: .atomic)
        try Data(snapshot.markdown.utf8).write(to: directory.appendingPathComponent("transcript.md"), options: .atomic)
        try Data(snapshot.originalSubtitles.utf8).write(to: directory.appendingPathComponent("transcript.srt"), options: .atomic)
    }
    func remove(_ id: UUID) throws {
        published.removeValue(forKey: id)
        let directory = root.appendingPathComponent("recordings/\(id.uuidString)")
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try appendChange(id: id, revision: 0, kind: "deleted")
        try refreshIndex(removing: id)
    }
    private func appendChange(id: UUID, revision: Int, kind: String) throws {
        let url = root.appendingPathComponent("events.json")
        var events: [AgentChange] = []
        if manager.fileExists(atPath: url.path) { events = try AgentCodec.decoder().decode([AgentChange].self, from: Data(contentsOf: url)) }
        events.append(AgentChange(sequence: (events.last?.sequence ?? 0) + 1, id: id, revision: revision, kind: kind))
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try AgentCodec.encoder().encode(Array(events.suffix(2000))).write(to: url, options: .atomic)
    }
    private func ensureChange(id: UUID, revision: Int) throws {
        let url = root.appendingPathComponent("events.json")
        let events = try AgentCodec.decoder().decode([AgentChange].self, from: Data(contentsOf: url))
        if !events.contains(where: { $0.id == id && $0.revision == revision && $0.kind == "updated" }) {
            try appendChange(id: id, revision: revision, kind: "updated")
        }
    }
    private func refreshIndex(record: AgentRecording? = nil, removing id: UUID? = nil) throws {
        let url = root.appendingPathComponent("index.json")
        var rows = (try? AgentCodec.decoder().decode([[String: String]].self, from: Data(contentsOf: url))) ?? []
        if let id { rows.removeAll { $0["id"] == id.uuidString } }
        if let record {
            rows.removeAll { $0["id"] == record.id.uuidString }
            rows.append(["id": record.id.uuidString, "title": record.title, "status": record.status, "revision": String(record.revision)])
        }
        try AgentCodec.encoder().encode(rows).write(to: url, options: .atomic)
        try Data(Self.instructions.utf8).write(to: root.appendingPathComponent("README.md"), options: .atomic)
    }
    static let instructions = """
    # RecordAI · 本机 Agent 接口 v1
    用App包内 Contents/MacOS/cohear 执行 list、read UUID --format json|md|txt|srt、audio UUID、changes --since N 或 mcp。
    MCP配置：command为该可执行文件的绝对路径，args为["mcp"]；不需要账号、不开放端口。
    默认只返回最终正文；read可显式增加--include-preview读取未定稿草稿。草稿不得视为最终转录。
    record.json为单文件原子快照；跨文件可能处于不同版本，优先读取它。schemaVersion=1；revision为单条版本，contentDigest标记内容变化。
    transcriptionReady表示完整正文已保存，ready还要求分人不处于processing；分人failed/partial/cancelled时文字仍可使用。
    events.json最多保留2000条，changes的resyncRequired=true时请重新list。删除事件不包含原文。
    音频以本机绝对路径引用，不复制；available在发布时检查，实际读取前需再次确认。不要修改内部Meetings目录。
    不包含历史AI总结、问答、笔记或账号凭据；旧附加内容仍保留在App原始数据中。
    本机文件遵循当前用户的文件权限。CLI读取不会启动App、恢复录音或加载模型。
    """
}
