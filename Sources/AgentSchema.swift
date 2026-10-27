import Foundation

/// 对外只读契约；与内部MeetingRecord分离，禁止将凭据或历史AI内容透传。
struct AgentAudio: Codable, Equatable {
    var part: Int
    var path: String
    var mime: String
    var duration: Double?
    var available: Bool
}
struct AgentSpeaker: Codable, Equatable {
    var id: String
    var name: String
}
struct AgentParagraph: Codable, Equatable {
    var id: UUID
    var text: String
    var separator: String
    var start: Double?
    var end: Double?
    var audioPart: Int?
    var localStart: Double?
    var speakers: [String]
    var speakerIDs: [String]
}
struct AgentRecording: Codable, Equatable {
    var schemaVersion = 1
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var status: String
    var language: String
    var duration: Double
    var revision: Int
    var contentDigest: String
    var transcriptionReady: Bool
    var speakerAnalysisStatus: String
    var ready: Bool
    var finalText: String
    var originalSubtitles: String
    var markdown: String
    var paragraphs: [AgentParagraph]
    var audioFiles: [AgentAudio]
    var speakers: [AgentSpeaker]
    var transcriptionEngine: String?
    var previewEngine: String?
    var captureWarnings: [String]? = nil
    var previewIsFinal = false
    var livePreview: String?
    var legacyContentAvailable: Bool
}
struct AgentChange: Codable {
    var sequence: Int
    var id: UUID
    var revision: Int
    var kind: String
}
struct AgentChanges: Codable {
    var cursor: Int
    var resyncRequired: Bool
    var events: [AgentChange]
}
enum AgentCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

/// 只读访问发布目录；不恢复会议、不创建目录、不启动App或模型。
struct AgentReadStore {
    let root: URL
    func read(_ id: UUID, includePreview: Bool = false) throws -> AgentRecording {
        let url = root.appendingPathComponent("recordings/\(id.uuidString)/record.json")
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else { throw AgentReadError.unsafePath }
        var record = try AgentCodec.decoder().decode(AgentRecording.self, from: Data(contentsOf: url))
        guard record.schemaVersion == 1, record.id == id else { throw AgentReadError.invalidRecord }
        if !includePreview { record.livePreview = nil }
        return record
    }
    func list() throws -> [AgentRecording] {
        let directories = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)
        return try directories.compactMap { directory -> AgentRecording? in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
            return try read(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func changes(since cursor: Int) throws -> AgentChanges {
        let events = try AgentCodec.decoder().decode([AgentChange].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
        let latest = events.last?.sequence ?? 0
        let first = events.first?.sequence ?? 1
        let resync = cursor < first - 1 || cursor > latest || cursor < 0
        return AgentChanges(cursor: latest, resyncRequired: resync, events: resync ? [] : events.filter { $0.sequence > cursor })
    }
}
enum AgentReadError: LocalizedError {
    case unsafePath, invalidRecord
    var errorDescription: String? { "本机转录快照无效或路径不安全，请在App设置中重新发布。" }
}
