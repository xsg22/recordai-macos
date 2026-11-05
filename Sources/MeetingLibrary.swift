import Foundation

/// 会议状态持久化到磁盘；应用重启后只恢复待处理记录，不擅自重启麦克风或模型任务。
enum MeetingStatus: String, Codable, CaseIterable {
    case recorded, recording, transcribing, completed, interrupted, failed
}

struct MeetingCitation: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var text: String
}
struct MeetingAssistantEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var created = Date()
    var question: String
    var answer: String
    var isLive: Bool
    var citations: [MeetingCitation] = []
    var contextWasTruncated = false
}

struct MeetingActionItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var isDone = false
    var assignee = ""
    var dueDate: Date?

    init(id: UUID = UUID(), title: String, isDone: Bool = false, assignee: String = "", dueDate: Date? = nil) {
        self.id = id; self.title = title; self.isDone = isDone; self.assignee = assignee; self.dueDate = dueDate
    }
    private enum CodingKeys: String, CodingKey { case id, title, isDone, assignee, dueDate }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        isDone = try values.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        assignee = try values.decodeIfPresent(String.self, forKey: .assignee) ?? ""
        dueDate = try values.decodeIfPresent(Date.self, forKey: .dueDate)
    }
}

struct MeetingAttachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var filename: String
    var displayName: String
    var bytes: Int64
}

enum OrganizationError: LocalizedError {
    case invalidName
    var errorDescription: String? {
        switch self {
        case .invalidName: return "名称应为 1–40 个字，不能换行或与已有名称重复。"
        }
    }
}
struct RecordingCollection: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var userId: UUID? = nil
    var syncDeleted: Bool? = nil
}
struct LibraryOrganization: Codable, Equatable {
    var groups: [RecordingCollection] = []
    func group(_ id: UUID?) -> RecordingCollection? { groups.first { $0.id == id } }
    mutating func setName(_ name: String, id: UUID?, owner: UUID? = nil) throws -> UUID {
        let owner = group(id)?.userId ?? owner
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, clean.rangeOfCharacter(from: .newlines) == nil,
              !groups.contains(where: { $0.id != id && $0.userId == owner && $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else { throw OrganizationError.invalidName }
        let key = id ?? UUID()
        if let id, !groups.contains(where: { $0.id == id }) { throw MeetingLibraryError.missingMeeting }
        if let index = groups.firstIndex(where: { $0.id == key }) { groups[index].name = clean }
        else { groups.append(RecordingCollection(id: key, name: clean, userId: owner)) }
        return key
    }
}

/// seconds 沿用 0.1 版的转录处理耗时；duration 才是会议音频时长。
struct MeetingRecord: Codable, Identifiable, Equatable {
    var identitySchemaVersion = 2
    var id: UUID = UUID()
    var title: String
    var created: Date = Date()
    var text: String
    var subtitles: String
    var language: String
    var seconds: Double
    var duration: Double = 0
    var notes: String = ""
    var summary: String? = nil
    var audioFiles: [String] = []
    var recordingSessionMode: RecordingSessionMode = .conference
    var continuousSegmentFiles: [String] = []
    /// 尚未定稿的录音片段；成功写入文字时与正文一起原子清除。
    var pendingAudioFiles: [String] = []
    var audioDurations: [String: Double] = [:]
    /// capture session UUID -> 托管音频文件名，与音频登记同一次原子保存。
    var importedCaptureSessions: [String: String] = [:]
    var status: MeetingStatus = .completed
    var isStarred = false
    var groupID: UUID? = nil
    var userId: UUID? = nil
    var syncContent: LibrarySyncRecording? = nil
    var syncedAudio: LibraryAudioArchive? = nil
    var source: RecordingOrigin = .macos
    var transcriptOrigin: TranscriptionOrigin = .local
    var actionItems: [MeetingActionItem] = []
    var attachments: [MeetingAttachment] = []
    var recoveryMessage: String? = nil
    /// 采集异常永久留作素材质量提示，不随ASR重试清除。
    var captureWarnings: [String] = []
    var updated: Date = Date()
    var previewText: String = ""
    var legacyLiveText = ""
    var liveUtterances: [LiveUtterance] = []
    var transcriptParagraphs: [TranscriptParagraph] = []
    var speakerNames: [String: String] = [:]
    /// Explicit user names stay verbatim when the interface language changes.
    var customSpeakerNameIDs: Set<String> = []
    var speakerAliases: [String: String] = [:]
    var speakerAnalysisStatus: SpeakerAnalysisStatus = .notStarted
    var speakerAnalysisMessage = ""
    var transcriptionEngine: String? = nil
    var previewEngine: String? = nil
    var enhancedNotes: String = ""
    var assistantEntries: [MeetingAssistantEntry] = []
    var summaryCitations: [MeetingCitation] = []
    var enhancedNotesCitations: [MeetingCitation] = []
    var summaryContextWasTruncated = false
    var enhancedNotesContextWasTruncated = false

    init(id: UUID = UUID(), title: String, created: Date = Date(), text: String = "",
         subtitles: String = "", language: String = "zh", seconds: Double = 0,
         duration: Double = 0, notes: String = "", summary: String? = nil,
         audioFiles: [String] = [], status: MeetingStatus = .completed,
         recoveryMessage: String? = nil, updated: Date = Date(), previewText: String = "") {
        self.id = id; self.title = title; self.created = created; self.text = text
        self.subtitles = subtitles; self.language = language; self.seconds = seconds
        self.duration = duration; self.notes = notes; self.summary = summary
        self.audioFiles = audioFiles; self.status = status
        self.recoveryMessage = recoveryMessage; self.updated = updated
        self.previewText = previewText
    }

    var canSelectFinalForSync: Bool {
        RecordingStateModel.allowsFinalTranscriptSync(transcriptOrigin,isFinal:status == .completed && pendingAudioFiles.isEmpty && (!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || syncContent != nil))
    }

    var stateModel: RecordingStateModel {
        let local: RecordingProcessingPhase = status == .transcribing ? .processing : (status == .failed ? .failed : (transcriptOrigin == .local && !text.isEmpty ? .ready : .notRequested))
        return RecordingStateModel(origin: source, capture: status == .recording ? .recording : (status == .interrupted ? .interrupted : .finished),
            localTranscription: local, remoteTranscription: syncContent?.formalOrigin == .remote ? .ready : .notRequested,
            transfer: .localOnly, audio: !audioFiles.isEmpty ? .unverified : (syncContent != nil ? .remoteOnly : .missing))
    }

    private enum CodingKeys: String, CodingKey {
        case identitySchemaVersion, groupID, customSpeakerNameIDs, userId, syncContent, syncedAudio, source, transcriptOrigin
        case captureWarnings, id, title, created, text, subtitles, language, seconds, duration, notes, summary, isStarred, actionItems, attachments
        case legacyLiveText, liveUtterances, transcriptParagraphs, speakerNames, speakerAliases, speakerAnalysisStatus, speakerAnalysisMessage
        case importedCaptureSessions, transcriptionEngine, previewEngine, pendingAudioFiles, audioDurations, audioFiles, recordingSessionMode, continuousSegmentFiles, status, recoveryMessage, updated, previewText, enhancedNotes, assistantEntries, summaryCitations, enhancedNotesCitations, summaryContextWasTruncated, enhancedNotesContextWasTruncated
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try values.decodeIfPresent(Int.self, forKey: .identitySchemaVersion) {
            guard version == 2 else { throw DecodingError.dataCorruptedError(forKey: .identitySchemaVersion, in: values, debugDescription: "Unsupported identity schema") }
        } else {
            // Pre-account local records are safe to read as unowned. Never guess an old cloud identity.
            struct AnyKey: CodingKey { var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int? { nil }; init?(intValue: Int) { return nil } }
            let raw = try decoder.container(keyedBy: AnyKey.self)
            let identityKeys = ["userId", "userID", "accountId", "accountID", "appleSub", "loginSubject", "syncContent", "syncedAudio"]
            guard try identityKeys.allSatisfy({ name in
                let key = AnyKey(stringValue: name)!
                if !raw.contains(key) { return true }
                return try raw.decodeNil(forKey: key)
            }) else { throw DecodingError.dataCorruptedError(forKey: .identitySchemaVersion, in: values, debugDescription: "Legacy account ownership cannot be inferred") }
        }
        syncedAudio = try values.decodeIfPresent(LibraryAudioArchive.self,forKey:.syncedAudio)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        created = try values.decode(Date.self, forKey: .created)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        subtitles = try values.decodeIfPresent(String.self, forKey: .subtitles) ?? ""
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        audioFiles = try values.decodeIfPresent([String].self, forKey: .audioFiles) ?? []
        recordingSessionMode = try values.decodeIfPresent(RecordingSessionMode.self, forKey: .recordingSessionMode) ?? .conference
        continuousSegmentFiles = try values.decodeIfPresent([String].self, forKey: .continuousSegmentFiles) ?? []
        importedCaptureSessions = try values.decodeIfPresent([String: String].self, forKey: .importedCaptureSessions) ?? [:]
        pendingAudioFiles = try values.decodeIfPresent([String].self, forKey: .pendingAudioFiles) ?? []
        audioDurations = try values.decodeIfPresent([String: Double].self, forKey: .audioDurations) ?? [:]
        status = try values.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .completed
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        userId = try values.decodeIfPresent(UUID.self, forKey: .userId)
        syncContent = try values.decodeIfPresent(LibrarySyncRecording.self, forKey: .syncContent)
        source = try values.decodeIfPresent(RecordingOrigin.self, forKey: .source) ?? syncContent.flatMap { RecordingOrigin(rawValue:$0.source) } ?? .macos
        transcriptOrigin = try values.decodeIfPresent(TranscriptionOrigin.self, forKey: .transcriptOrigin) ?? (syncContent == nil ? .local : .remote)
        isStarred = try values.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        actionItems = try values.decodeIfPresent([MeetingActionItem].self, forKey: .actionItems) ?? []
        attachments = try values.decodeIfPresent([MeetingAttachment].self, forKey: .attachments) ?? []
        captureWarnings = try values.decodeIfPresent([String].self, forKey: .captureWarnings) ?? []
        recoveryMessage = try values.decodeIfPresent(String.self, forKey: .recoveryMessage)
        updated = try values.decodeIfPresent(Date.self, forKey: .updated) ?? created
        previewText = try values.decodeIfPresent(String.self, forKey: .previewText) ?? ""
        legacyLiveText = try values.decodeIfPresent(String.self, forKey: .legacyLiveText) ?? ""
        liveUtterances = try values.decodeIfPresent([LiveUtterance].self, forKey: .liveUtterances) ?? []
        transcriptParagraphs = try values.decodeIfPresent([TranscriptParagraph].self, forKey: .transcriptParagraphs) ?? []
        speakerNames = try values.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        customSpeakerNameIDs = try values.decodeIfPresent(Set<String>.self, forKey: .customSpeakerNameIDs) ?? []
        speakerAliases = try values.decodeIfPresent([String: String].self, forKey: .speakerAliases) ?? [:]
        speakerAnalysisStatus = try values.decodeIfPresent(SpeakerAnalysisStatus.self, forKey: .speakerAnalysisStatus) ?? .notStarted
        speakerAnalysisMessage = try values.decodeIfPresent(String.self, forKey: .speakerAnalysisMessage) ?? ""
        transcriptionEngine = try values.decodeIfPresent(String.self, forKey: .transcriptionEngine)
        previewEngine = try values.decodeIfPresent(String.self, forKey: .previewEngine)
        enhancedNotes = try values.decodeIfPresent(String.self, forKey: .enhancedNotes) ?? ""
        assistantEntries = try values.decodeIfPresent([MeetingAssistantEntry].self, forKey: .assistantEntries) ?? []
        summaryCitations = try values.decodeIfPresent([MeetingCitation].self, forKey: .summaryCitations) ?? []
        enhancedNotesCitations = try values.decodeIfPresent([MeetingCitation].self, forKey: .enhancedNotesCitations) ?? []
        summaryContextWasTruncated = try values.decodeIfPresent(Bool.self, forKey: .summaryContextWasTruncated) ?? false
        enhancedNotesContextWasTruncated = try values.decodeIfPresent(Bool.self, forKey: .enhancedNotesContextWasTruncated) ?? false
    }
}

enum MeetingLibraryError: LocalizedError {
    case unsafeAudioPath, missingAudio, missingAttachment, invalidTitle, missingMeeting
    var errorDescription: String? {
        switch self {
        case .unsafeAudioPath: return "录音文件路径无效，无法访问录音目录以外的文件。"
        case .missingAudio: return "找不到音频文件，请重新导入。"
        case .missingAttachment: return "找不到本地附件，请重新添加。"
        case .invalidTitle: return "录音标题不能为空。"
        case .missingMeeting: return "找不到这条录音记录。"
        }
    }
}

/// 每个会议独立存储。调用方应串行访问（AppState 在 MainActor 调用）。
/// 音频只保存会议目录内相对文件名；标题从不参与路径拼接。
final class MeetingLibrary {
    let root: URL
    var activeSyncUserId: UUID?
    var didChange: (() -> Void)?
    private let manager: FileManager
    private(set) var warnings: [String] = []
    private(set) var publicationError: String?
    private lazy var publisher = AgentDataPublisher(libraryRoot: root)
    private var meetingsDirectory: URL { root.appendingPathComponent("Meetings", isDirectory: true) }

    init(root: URL, manager: FileManager = .default) throws {
        self.root = root
        self.manager = manager
        try manager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
        try migrateLegacyHistory()
        _ = try recoverInterrupted()
        republishAgentData()
    }

    private func rawOrganization() throws -> LibraryOrganization {
        let url = root.appendingPathComponent("organization.json")
        guard manager.fileExists(atPath: url.path) else { return LibraryOrganization() }
        return try JSONDecoder().decode(LibraryOrganization.self, from: Data(contentsOf: url))
    }
    func organization() throws -> LibraryOrganization {
        var value = try rawOrganization()
        value.groups = value.groups.filter { ($0.userId == nil || $0.userId == activeSyncUserId) && $0.syncDeleted != true }
        return value
    }
    func saveOrganization(_ visible: LibraryOrganization) throws {
        let raw = try rawOrganization().groups
        let visibleIds = Set(visible.groups.map(\.id))
        let hidden = raw.filter { !visibleIds.contains($0.id) && ($0.syncDeleted == true || ($0.userId != nil && $0.userId != activeSyncUserId)) }
        let removed = raw.filter { !visibleIds.contains($0.id) && $0.syncDeleted != true && $0.userId != nil && $0.userId == activeSyncUserId }.map { row -> RecordingCollection in var row = row; row.syncDeleted = true; return row }
        let value = LibraryOrganization(groups: visible.groups + hidden + removed)

        for rows in [value.groups] {
            guard Set(rows.map(\.id)).count == rows.count else { throw OrganizationError.invalidName }
            for owner in Set(rows.map { $0.userId }) {
                var validated = LibraryOrganization()
                for row in rows where row.userId == owner && row.syncDeleted != true { _ = try validated.setName(row.name, id: nil) }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: root.appendingPathComponent("organization.json"), options: .atomic)
        republishAgentData(); didChange?()
    }

    func syncDeletions(_ userId:UUID) throws -> Set<String> {
        let groups = try rawOrganization().groups.filter { $0.userId == userId && $0.syncDeleted == true }.map { LibrarySyncValue.key(.group,$0.id) }
        let records = try listTrashed().filter { $0.userId == userId }.map { LibrarySyncValue.key(.recording,$0.id) }
        return Set(groups + records)
    }
    func directory(for id: UUID) -> URL {
        meetingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func load(_ id: UUID, includingHidden: Bool = false) throws -> MeetingRecord {
        let url = directory(for: id).appendingPathComponent("meeting.json")
        guard manager.fileExists(atPath: url.path) else { throw MeetingLibraryError.missingMeeting }
        let data = try Data(contentsOf: url)
        var record = try JSONDecoder().decode(MeetingRecord.self, from: data)
        guard record.id == id, includingHidden || record.userId == nil || record.userId == activeSyncUserId else { throw MeetingLibraryError.missingMeeting }
        // 0.14.0 未保存会话类型；仅在字段缺失且存在切片清单时识别旧持续录音。
        if record.recordingSessionMode == .conference,
           let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           fields["recordingSessionMode"] == nil,
           manager.fileExists(atPath: directory(for: id).appendingPathComponent("Capture/Segments/segments.json").path) {
            record.recordingSessionMode = .continuous
        }
        let catalog = try organization()
        if record.userId == nil { record.groupID = catalog.group(record.groupID)?.id }
        else if let groupId = record.groupID, try rawOrganization().groups.contains(where: { $0.id == groupId && $0.syncDeleted == true }) { record.groupID = nil }
        else if let group = catalog.group(record.groupID), group.userId != record.userId { record.groupID = nil }
        return record
    }

    /// 单条损坏不会隐藏其他会议；warnings 供界面显示，原文件保留以便修复。
    func list(query: String = "") throws -> [MeetingRecord] {
        warnings.removeAll()
        let directories = try manager.contentsOfDirectory(at: meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var result: [MeetingRecord] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                let record = try load(id,includingHidden:true)
                guard record.userId == nil || record.userId == activeSyncUserId else { continue }
                let search = [record.title, record.text].joined(separator: "\n")
                if query.isEmpty || search.localizedStandardContains(query) { result.append(record) }
            } catch { warnings.append("录音 \(id.uuidString) 读取失败：\(error.localizedDescription)") }
        }
        return result.sorted { $0.created > $1.created }
    }

    @discardableResult
    func save(_ record: MeetingRecord) throws -> MeetingRecord {
        guard record.userId == nil || record.userId == activeSyncUserId else { throw MeetingLibraryError.missingMeeting }
        let existingURL = directory(for:record.id).appendingPathComponent("meeting.json")
        if manager.fileExists(atPath:existingURL.path) {
            let existing = try load(record.id,includingHidden:true)
            guard existing.userId == nil || existing.userId == record.userId else { throw MeetingLibraryError.missingMeeting }
        }
        guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingLibraryError.invalidTitle
        }
        for file in record.audioFiles { _ = try audioURL(file, meeting: record.id) }
        for attachment in record.attachments { _ = try attachmentURL(attachment, meeting: record.id) }
        var saved = record
        let catalog = try organization()
        if saved.userId == nil { saved.groupID = catalog.group(saved.groupID)?.id }
        else if let group = catalog.group(saved.groupID), group.userId != saved.userId { throw OrganizationError.invalidName }
        saved.updated = Date()
        let directory = directory(for: saved.id)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: directory.appendingPathComponent("meeting.json"), options: .atomic)
        do { try publisher.publish(saved, libraryRoot: root); publicationError = nil }
        catch { publicationError = "本机Agent快照更新失败，录音原件已保存：\(error.localizedDescription)" }
        didChange?(); return saved
    }

    @discardableResult
    func rename(_ id: UUID, title: String) throws -> MeetingRecord {
        var record = try load(id)
        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try save(record)
    }

    /// 先落 metadata，再由录音器写入此地址，崩溃后依然能发现未完成录音。
    func recordingURL(for record: inout MeetingRecord, extension suffix: String = "m4a") throws -> URL {
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw MeetingLibraryError.unsafeAudioPath
        }
        let file = UUID().uuidString + "." + suffix
        let destination = try audioURL(file, meeting: record.id)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        record.audioFiles.append(file)
        record.status = .recording
        do { record = try save(record) }
        catch { record.audioFiles.removeAll { $0 == file }; throw error }
        return destination
    }

    /// 复制而非移动用户原始文件。复制完成后才写元数据；保存失败则撤销复制。
    @discardableResult
    func importAudio(_ source: URL, into record: inout MeetingRecord, recordingDuration: Double? = nil, captureSession: UUID? = nil) throws -> URL {
        if let duration = recordingDuration, !duration.isFinite || duration < 0 {
            throw MeetingLibraryError.missingAudio
        }
        if let captureSession, let file = record.importedCaptureSessions[captureSession.uuidString] {
            let existing = try audioURL(file, meeting: record.id)
            guard manager.fileExists(atPath: existing.path) else { throw MeetingLibraryError.missingAudio }
            return existing
        }
        let original = record
        var isDirectory: ObjCBool = false
        guard source.isFileURL, manager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MeetingLibraryError.missingAudio
        }
        let suffix = source.pathExtension.lowercased()
        guard suffix.isEmpty || suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw MeetingLibraryError.unsafeAudioPath
        }
        let file = UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix)
        let destination = try audioURL(file, meeting: record.id)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: source, to: destination)
        record.audioFiles.append(file)
        if let captureSession { record.importedCaptureSessions[captureSession.uuidString] = file }
        if let duration = recordingDuration {
            record.pendingAudioFiles.append(file)
            record.audioDurations[file] = duration
            record.duration += duration
            record.status = .recorded
        }
        do { record = try save(record) }
        catch {
            record = original
            try? manager.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// 后台复制完成后才登记；元数据与session去重标记一起保存，失败不遗留半份会议。
    func recoveryDestination(for id: UUID) throws -> URL {
        let url = try audioURL(UUID().uuidString + ".m4a", meeting: id)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
    @discardableResult
    func registerRecovery(_ destination: URL, duration: Double, session: UUID, warnings: [String] = [], into record: inout MeetingRecord) throws -> URL {
        let validated = try audioURL(destination.lastPathComponent, meeting: record.id)
        guard validated.standardizedFileURL == destination.standardizedFileURL, manager.fileExists(atPath: validated.path),
              duration.isFinite, duration > 0 else { throw MeetingLibraryError.unsafeAudioPath }
        if let file = record.importedCaptureSessions[session.uuidString] {
            let existing = try audioURL(file, meeting: record.id)
            guard manager.fileExists(atPath: existing.path) else { throw MeetingLibraryError.missingAudio }
            if destination != existing { try? manager.removeItem(at: destination) }
            return existing
        }
        let original = record
        let file = destination.lastPathComponent
        record.audioFiles.append(file); record.pendingAudioFiles.append(file)
        record.audioDurations[file] = duration; record.duration += duration
        record.importedCaptureSessions[session.uuidString] = file
        record.captureWarnings.append(contentsOf: warnings)
        record.status = .recorded
        record.recoveryMessage = "录音已恢复并保存，可继续转录未完成片段。"
        do { record = try save(record); return validated }
        catch { record = original; try? manager.removeItem(at: destination); throw error }
    }

    func audioURLs(for record: MeetingRecord) throws -> [URL] {
        try record.audioFiles.map { try audioURL($0, meeting: record.id) }
    }

    func attachmentURL(_ attachment: MeetingAttachment, meeting id: UUID) throws -> URL {
        let filename = attachment.filename
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else { throw MeetingLibraryError.unsafeAudioPath }
        let folder = directory(for: id).appendingPathComponent("Attachments", isDirectory: true)
        let destination = folder.appendingPathComponent(filename)
        for component in [directory(for: id), folder, destination] {
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw MeetingLibraryError.unsafeAudioPath }
        }
        return directory(for: id).resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("Attachments", isDirectory: true).appendingPathComponent(filename)
    }

    @discardableResult func importAttachment(_ source: URL, into record: inout MeetingRecord) throws -> MeetingAttachment {
        let canonical = source.resolvingSymlinksInPath()
        let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MeetingLibraryError.unsafeAudioPath }
        let suffix = canonical.pathExtension.prefix(16)
        let ext = suffix.allSatisfy { $0.isLetter || $0.isNumber } ? String(suffix) : ""
        let filename = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let attachment = MeetingAttachment(filename: filename, displayName: source.lastPathComponent, bytes: Int64(values.fileSize ?? 0))
        let destination = try attachmentURL(attachment, meeting: record.id)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: canonical, to: destination)
        let original = record
        record.attachments.append(attachment)
        do { record = try save(record) }
        catch { record = original; try? manager.removeItem(at: destination); throw error }
        return attachment
    }

    /// 移除附件仅移入会议自身的附件回收目录，不删除用户选择的源文件。
    func removeAttachment(_ id: UUID, from record: inout MeetingRecord) throws {
        guard let attachment = record.attachments.first(where: { $0.id == id }) else { return }
        let source = try attachmentURL(attachment, meeting: record.id)
        let folder = directory(for: record.id).appendingPathComponent("RemovedAttachments", isDirectory: true)
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MeetingLibraryError.unsafeAudioPath }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(attachment.filename)
        try manager.moveItem(at: source, to: destination)
        let original = record
        record.attachments.removeAll { $0.id == id }
        do { record = try save(record) }
        catch { record = original; try? manager.moveItem(at: destination, to: source); throw error }
    }

    private func audioURL(_ filename: String, meeting id: UUID) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else { throw MeetingLibraryError.unsafeAudioPath }
        let audioDirectory = directory(for: id).appendingPathComponent("Audio", isDirectory: true)
        let destination = audioDirectory.appendingPathComponent(filename)
        // resolvingSymlinksInPath 对目标不存在的符号链接不一定解析，显式拒绝所有链接。
        for component in [directory(for: id), audioDirectory, destination] {
            if let attributes = try? manager.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw MeetingLibraryError.unsafeAudioPath
            }
        }
        // 先解析已存在的会议父目录，再追加受控文件名。目标尚不存在时，
        // Foundation可能保留/private/tmp别名，不能把它误判为目录逃逸。
        let canonicalMeeting = directory(for: id).resolvingSymlinksInPath().standardizedFileURL
        return canonicalMeeting.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent(filename)

    }

    @discardableResult
    func recoverInterrupted() throws -> [MeetingRecord] {
        var recovered: [MeetingRecord] = []
        for var record in try list() where record.status == .recording || record.status == .transcribing || record.speakerAnalysisStatus == .processing {
            if record.status == .completed {
                record.speakerAnalysisStatus = .cancelled
                record.speakerAnalysisMessage = "上次发言人分析中断，转录正文已保留。"
                recovered.append(try save(record)); continue
            }
            let previous = record.status
            record.status = .interrupted
            record.recoveryMessage = previous == .recording
                ? "上次录音未正常结束。已保留现有音频，请试听后继续转录；损坏的音频可能需要修复。"
                : "上次转录未完成。音频和已有文本已保留，可以重新转录。"
            recovered.append(try save(record))
        }
        return recovered
    }

    func markdown(for record: MeetingRecord) -> String { AgentDataPublisher.markdown(record) }

    func exportMarkdown(_ record: MeetingRecord, to destination: URL) throws {
        try markdown(for: record).write(to: destination, atomically: true, encoding: .utf8)
    }

    private var trashDirectory: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    private func validateTrashDirectory() throws {
        if (try? trashDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MeetingLibraryError.unsafeAudioPath
        }
    }

    func listTrashed() throws -> [MeetingRecord] {
        try validateTrashDirectory()
        guard manager.fileExists(atPath: trashDirectory.path) else { return [] }
        return try manager.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .compactMap { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent),
                      (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let data = try? Data(contentsOf: directory.appendingPathComponent("meeting.json")),
                      var record = try? JSONDecoder().decode(MeetingRecord.self, from: data), record.id == id, record.userId == nil || record.userId == activeSyncUserId else { return nil }
                let catalog = try organization()
                if record.userId == nil { record.groupID = catalog.group(record.groupID)?.id }
        else if let groupId = record.groupID, try rawOrganization().groups.contains(where: { $0.id == groupId && $0.syncDeleted == true }) { record.groupID = nil }
        else if let group = catalog.group(record.groupID), group.userId != record.userId { record.groupID = nil }
                return record
            }.sorted { $0.updated > $1.updated }
    }

    /// 移入本应用回收站；恢复时完整移回，不触碰导入前的源文件。
    func trash(_ id: UUID) throws {
        _ = try load(id)
        try validateTrashDirectory()
        try manager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try manager.moveItem(at: directory(for: id), to: trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
        do { try publisher.remove(id); publicationError = nil }
        catch { publicationError = "录音已移入回收站，本机Agent快照清理失败，请重新发布。" }
        didChange?()
    }

    @discardableResult func restoreTrashed(_ id: UUID) throws -> MeetingRecord {
        try validateTrashDirectory()
        let source = trashDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              try listTrashed().contains(where: { $0.id == id }) else { throw MeetingLibraryError.missingMeeting }
        // moveItem 拒绝覆盖；与活跃库同名时保留两份原件并报告错误。
        try manager.moveItem(at: source, to: directory(for: id))
        let restored = try load(id)
        do { try publisher.publish(restored, libraryRoot: root); publicationError = nil }
        catch { publicationError = "录音已恢复，本机Agent快照暂未更新，请重新发布。" }
        didChange?(); return restored
    }

    /// 用于初次发布和显式修复；不改变会议状态。
    func republishAgentData() {
        do {
            try publisher.prepare()
            _ = try organization() // 分类索引损坏不能被误判为全部资料已删除。
            let records = try list()
            let ids = Set(records.map(\.id))
            let publicRoot = root.appendingPathComponent("AgentData/recordings")
            let indexURL = root.appendingPathComponent("AgentData/index.json")
            if let data = try? Data(contentsOf: indexURL), let index = try? AgentCodec.decoder().decode([[String: String]].self, from: data) {
                for row in index {
                    if let value = row["id"], let id = UUID(uuidString: value), !ids.contains(id) { try publisher.remove(id) }
                }
            }
            if let entries = try? manager.contentsOfDirectory(at: publicRoot, includingPropertiesForKeys: nil) {
                for entry in entries {
                    if let id = UUID(uuidString: entry.lastPathComponent), !ids.contains(id) { try publisher.remove(id) }
                }
            }
            for record in records { try publisher.publish(record, libraryRoot: root) }
            publicationError = nil
        } catch { publicationError = "本机Agent快照更新失败，录音原件已保留：\(error.localizedDescription)" }
    }

    private func migrateLegacyHistory() throws {
        let legacy = root.appendingPathComponent("history.json")
        let marker = root.appendingPathComponent("history-v1-migrated.json")
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: marker.path) else { return }
        let bytes = try Data(contentsOf: legacy)
        let records = try JSONDecoder().decode([MeetingRecord].self, from: bytes)
        // 成功解码后先备份；中途失败重启会按 UUID 跳过已迁移记录，绝不覆盖编辑。
        let backup = root.appendingPathComponent("history-v0.1-backup.json")
        if !manager.fileExists(atPath: backup.path) { try bytes.write(to: backup, options: .atomic) }
        for record in records {
            let metadata = directory(for: record.id).appendingPathComponent("meeting.json")
            if !manager.fileExists(atPath: metadata.path) { _ = try save(record) }
        }
        let receipt = "{\"version\":1,\"count\":\(records.count)}\n"
        try Data(receipt.utf8).write(to: marker, options: .atomic)
        // 旧版没有保存音频关联关系，保留 Recordings/ 和 history.json，避免错误猜测配对。
    }
}

/// Pure gate used by automatic Live Q&A; committed transcript events are the only triggers.
enum LiveQASchedule {
    static func shouldRun(now: Date, lastRun: Date, enabled: Bool, recording: Bool, paused: Bool,
                          preparing: Bool, assistantBusy: Bool, modelReady: Bool, pendingText: String) -> Bool {
        enabled && recording && !paused && !preparing && !assistantBusy && modelReady
            && now.timeIntervalSince(lastRun) >= 15
            && !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
