import Foundation

@MainActor final class MacLibrarySyncAdapter: LibrarySyncAdapter {
    var beforeRead: (() throws -> Void)?
    let library: MeetingLibrary
    init(library: MeetingLibrary) { self.library = library }
    func deletions(userId: UUID) throws -> Set<String> { try library.syncDeletions(userId) }
    func activate(userId: UUID?) throws { library.activeSyncUserId = userId; library.republishAgentData() }
    func values(userId: UUID) throws -> [LibrarySyncValue] {
        try beforeRead?()
        guard library.activeSyncUserId == userId else { throw LibrarySyncError.invalidData }
        let groups = try library.organization().groups.filter { $0.userId == userId }
        var values = groups.map { LibrarySyncValue.group(LibrarySyncGroup(id:$0.id,name:$0.name)) }
        let records = try library.list()
        guard library.warnings.isEmpty else { throw LibrarySyncError.invalidData }
        for record in records where record.userId == userId {
            if record.status == .completed && record.pendingAudioFiles.isEmpty { values.append(.recording(project(record))) }
            else {
                // While capture/ASR is active, keep the enrolled final snapshot; never read live fields.
                guard var final = record.syncContent else { throw LibrarySyncError.unavailable }
                final.title = record.title;final.groupId = record.groupID;final.isStarred = record.isStarred
                final.durationMs = LibrarySyncCodec.milliseconds(record.duration); final.language = record.language
                values.append(.recording(final))
            }
        }
        return values
    }
    func enrollAll(userId: UUID) throws {
        try beforeRead?()
        guard library.activeSyncUserId == userId else { throw LibrarySyncError.invalidData }
        let records = try library.list()
        guard library.warnings.isEmpty else { throw LibrarySyncError.invalidData }
        var organization = try library.organization()
        var groupsChanged = false
        for index in organization.groups.indices where organization.groups[index].userId == nil {
            organization.groups[index].userId = userId; groupsChanged = true
        }
        if groupsChanged { try library.saveOrganization(organization) }
        for var record in records where record.userId == nil && record.status != .recording {
            record.userId = userId; record.syncContent = project(record)
            _ = try library.save(record)
        }
    }
    private func project(_ record: MeetingRecord) -> LibrarySyncRecording {
        var paragraphs: [LibrarySyncParagraph] = []
        var names: [UUID:String] = [:]
        func speaker(_ key: String) -> UUID {
            let key = record.canonicalSpeaker(key)
            let id = UUID(uuidString:key) ?? LibrarySyncCodec.stableID(record.id.uuidString + ":speaker:" + key)
            names[id] = record.speakerNames[key] ?? ""; return id
        }
        let hasFinal = record.status == .completed && record.pendingAudioFiles.isEmpty
        if !hasFinal {
            paragraphs = record.syncContent?.paragraphs ?? []
            for speaker in record.syncContent?.speakers ?? [] { names[speaker.id] = speaker.name }
        } else if record.hasCurrentParagraphs {
            paragraphs = record.transcriptParagraphs.map { row in
                let start = LibrarySyncCodec.milliseconds(row.start), end = LibrarySyncCodec.milliseconds(row.end)
                return LibrarySyncParagraph(id:row.id,text:row.text,separator:row.separator,startMs:start != nil && end != nil ? start : nil,endMs:start != nil && end != nil ? end : nil,speakerIds:row.speakerIDs.map(speaker))
            }
        } else if !record.text.isEmpty {
            paragraphs = [LibrarySyncParagraph(id:LibrarySyncCodec.stableID(record.id.uuidString+":body"),text:record.text,separator:"",startMs:nil,endMs:nil,speakerIds:[])]
        }
        let content = LibrarySyncRecording(id:record.id,title:record.title,createdAt:record.syncContent?.createdAt ?? LibrarySyncCodec.date(record.created),durationMs:record.duration == 0 && record.syncContent?.durationMs == nil ? nil : LibrarySyncCodec.milliseconds(record.duration),source:record.syncContent?.source ?? record.source.rawValue,language:record.language,isStarred:record.isStarred,groupId:record.groupID,speakers:names.map { LibrarySyncSpeaker(id:$0.key,name:$0.value) }.sorted { $0.id.uuidString < $1.id.uuidString },paragraphs:paragraphs)
        var final = content
        final.transcriptOrigin = paragraphs.isEmpty ? nil : (record.transcriptOrigin == .local ? .local : (record.syncContent?.transcriptOrigin ?? .local))
        return final
    }
    func enroll(recordingIds: Set<UUID>, userId: UUID) throws {
        guard library.activeSyncUserId == userId else { throw LibrarySyncError.invalidData }
        var organization = try library.organization()
        for id in recordingIds {
            var record = try library.load(id)
            guard record.userId == nil || record.userId == userId else { throw LibrarySyncError.invalidData }
            guard record.canSelectFinalForSync else { throw LibrarySyncError.unavailable }
            if let group = organization.group(record.groupID), group.userId != userId {
                let own = organization.groups.first { $0.userId == userId && $0.name == group.name } ?? RecordingCollection(name:group.name,userId:userId)
                if !organization.groups.contains(where: { $0.id == own.id }) { organization.groups.append(own) }
                record.groupID = own.id
            }
            try library.saveOrganization(organization)
            record.userId = userId;record.syncContent = project(record); _ = try library.save(record)
        }
    }
    func remember(_ entity: LibrarySyncEntity, userId: UUID) throws {
        guard library.activeSyncUserId == userId else { throw LibrarySyncError.invalidData }
        if let content = entity.value?.recording, var record = try? library.load(entity.id), record.userId == userId, record.syncContent != content {
            record.syncContent = content; _ = try library.save(record)
        }
    }
    func apply(_ entity: LibrarySyncEntity, userId: UUID) throws {
        guard library.activeSyncUserId == userId else { throw LibrarySyncError.invalidData }
        if entity.kind == .group {
            var organization = try library.organization()
            if let existing = organization.group(entity.id), existing.userId != userId { throw LibrarySyncError.invalidData }
            organization.groups.removeAll { $0.id == entity.id }
            if let group = entity.value?.group { organization.groups.append(RecordingCollection(id:group.id,name:group.name,userId:userId)) }
            try library.saveOrganization(organization); return
        }
        let existing = try? library.load(entity.id,includingHidden:true)
        if let existing, existing.userId != userId { throw LibrarySyncError.invalidData }
        if let existing, existing.status == .recording || existing.status == .transcribing { throw LibrarySyncError.unavailable }
        guard let content = entity.value?.recording else {
            if existing != nil { try library.trash(entity.id) }; return
        }
        // Restore a previously soft-deleted item without destroying its retained original audio.
        if existing == nil, try library.listTrashed().contains(where: { $0.id == entity.id && $0.userId == userId }) { _ = try library.restoreTrashed(entity.id) }
        var record = (try? library.load(entity.id)) ?? MeetingRecord(id:content.id,title:content.title)
        guard Set(record.transcriptParagraphs.map(\.id)).count == record.transcriptParagraphs.count else { throw LibrarySyncError.invalidData }
        let previous = Dictionary(uniqueKeysWithValues: record.transcriptParagraphs.map { ($0.id,$0) })
        record.title = content.title; record.created = LibrarySyncCodec.date(content.createdAt) ?? record.created
        record.duration = Double(content.durationMs ?? 0) / 1000; record.language = content.language
        record.isStarred = content.isStarred; record.groupID = content.groupId
        record.source = RecordingOrigin(rawValue:content.source) ?? .unknown
        record.transcriptOrigin = content.formalOrigin
        let keepUnfinished = content.paragraphs.isEmpty && existing.map { $0.status != .completed && $0.syncContent?.paragraphs.isEmpty != false } == true
        if !keepUnfinished { record.text = content.text }
        record.userId = userId; record.syncContent = content
        if !content.paragraphs.isEmpty || existing == nil { record.status = .completed }
        if !keepUnfinished {
        record.speakerNames = Dictionary(uniqueKeysWithValues: content.speakers.map { ($0.id.uuidString,$0.name) })
        record.customSpeakerNameIDs = Set(record.speakerNames.keys); record.speakerAliases = [:]
        record.transcriptParagraphs = content.paragraphs.map { row in
            TranscriptParagraph(id:row.id,text:row.text,separator:row.separator,start:row.startMs.map { Double($0)/1000 },end:row.endMs.map { Double($0)/1000 },audioFile:previous[row.id]?.audioFile,speakerIDs:row.speakerIds.map(\.uuidString),localStart:previous[row.id]?.localStart)
        }
        }
        _ = try library.save(record)
    }
}
