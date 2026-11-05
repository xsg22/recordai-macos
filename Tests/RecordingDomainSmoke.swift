import Foundation

@main struct RecordingDomainSmoke {
    static func check(_ condition: Bool) { precondition(condition) }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-domain-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = try MeetingLibrary(root:root),adapter = MacLibrarySyncAdapter(library:library),account = UUID()
        try adapter.activate(userId:account)
        var local = MeetingRecord(title:"selectable local final",text:"confirmed local ASR")
        _ = try library.save(local)
        check(try adapter.values(userId:account).isEmpty) // A login alone never enrolls local finals.
        check(local.canSelectFinalForSync)
        check(local.stateModel.localTranscription == .ready && local.stateModel.remoteTranscription == .notRequested)
        var provisional = MeetingRecord(title:"live",text:"private provisional",status:.recording,previewText:"private live")
        provisional = try library.save(provisional)
        do { try adapter.enroll(recordingIds:[provisional.id],userId:account);fatalError("live transcript enrolled") } catch LibrarySyncError.unavailable {}
        try adapter.enroll(recordingIds:[local.id],userId:account)
        local = try library.load(local.id)
        let final = try adapter.values(userId:account).compactMap(\.recording).first!
        check(final.formalOrigin == .local && final.text == local.text)
        check(local.userId == account && local.transcriptOrigin == .local)
        check(!RecordingStateModel.allowsRemoteTranscript(.local)) // No implicit cloud AI/title permission.
        check(RecordingStateModel.allowsFinalTranscriptSync(.local,isFinal:true))
        check(!RecordingStateModel.allowsFinalTranscriptSync(.local,isFinal:false))
        var live = local;live.status = .transcribing;live.text = "private interim text";live.previewText = "private live captions"
        _ = try library.save(live)
        check(try adapter.values(userId:account).compactMap(\.recording).first == final)
        _ = try library.save(local)
        var incoming = final;incoming.paragraphs[0].text = "chosen cloud revision of local final"
        try adapter.apply(LibrarySyncEntity(kind:.recording,id:local.id,version:2,value:.recording(incoming)),userId:account)
        let updated = try library.load(local.id)
        check(updated.text == incoming.text && updated.transcriptOrigin == .local)
        check(updated.stateModel.remoteTranscription == .notRequested)
        let archive = try JSONDecoder().decode(MeetingRecord.self,from:JSONEncoder().encode(updated))
        check(archive.transcriptOrigin == .local && archive.canSelectFinalForSync)
        let remoteID = UUID(),content = LibrarySyncRecording(id:remoteID,title:"remote",createdAt:"2026-11-04T00:00:00.000Z",durationMs:5250,source:"watch",language:"zh",isStarred:false,groupId:nil,speakers:[],paragraphs:[LibrarySyncParagraph(id:UUID(),text:"remote formal",separator:"",startMs:0,endMs:5250,speakerIds:[])])
        try adapter.apply(LibrarySyncEntity(kind:.recording,id:remoteID,version:1,value:.recording(content)),userId:account)
        let remote = try library.load(remoteID)
        check(remote.source == .watch && remote.transcriptOrigin == .remote && remote.duration == 5.25)
        check(remote.stateModel.remoteTranscription == .ready && remote.stateModel.audio == .remoteOnly)
        try adapter.activate(userId:UUID());check(try library.list().allSatisfy { $0.id != local.id && $0.id != remoteID })
        let state = RecordingStateModel(origin:.watch,capture:.finished,localTranscription:.ready,remoteTranscription:.notRequested,transfer:.sending,audio:.unverified)
        check(state.presentation == .syncing)
        check(try JSONDecoder().decode(RecordingStateModel.self,from:JSONEncoder().encode(state)) == state)
        print("PASS: selected local final sync, no automatic enrollment/live caption upload, preserved provenance, chosen remote projection, account scope and state round-trip")
    }
}
