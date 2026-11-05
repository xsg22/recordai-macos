import Foundation
import AVFoundation

@main struct LibraryAutomaticSyncSmoke {
    @MainActor static func main() async throws {
        let server = URL(string:CommandLine.arguments[1])!, root = URL(fileURLWithPath:CommandLine.arguments[2])
        func check(_ value:Bool,_ message:String) { precondition(value,message) }
        func login(_ name:String) async throws -> (LibrarySyncHTTP,LibraryAudioHTTP,UUID) {
            var request = URLRequest(url:server.appendingPathComponent("v1/auth/account"));request.httpMethod = "POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:["username":name,"password":"synthetic-password"])
            let (data,response) = try await URLSession.shared.data(for:request)
            check((response as? HTTPURLResponse)?.statusCode == 200,"isolated login")
            let token = (try JSONSerialization.jsonObject(with:data) as! [String:Any])["token"] as! String
            let http = LibrarySyncHTTP(server:server,token:token)
            return (http,LibraryAudioHTTP(server:server,token:token),try await http.identity().userId)
        }
        func fixture(_ library:MeetingLibrary,_ record:MeetingRecord) throws -> MeetingRecord {
            var record = try library.save(record)
            let dir = library.directory(for:record.id).appendingPathComponent("Audio")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let url = dir.appendingPathComponent("synthetic.wav"), format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!;buffer.frameLength = 16000
            for n in 0..<16000 { buffer.floatChannelData![0][n] = Float(sin(Double(n)*0.07)*0.1) }
            let file = try AVAudioFile(forWriting:url,settings:format.settings);try file.write(from:buffer)
            record.audioFiles = [url.lastPathComponent];record.duration = 1;record.audioDurations = [url.lastPathComponent:1]
            return try library.save(record)
        }
        let (http,audioHTTP,user) = try await login("qa_auto_"+UUID().uuidString.prefix(8))
        let library = try MeetingLibrary(root:root.appendingPathComponent("mac")),adapter = MacLibrarySyncAdapter(library:library)
        var groups = try library.organization();let group = RecordingCollection(name:"Automatic group"),emptyGroup = RecordingCollection(name:"Empty group")
        groups.groups = [group,emptyGroup];try library.saveOrganization(groups)
        var final = MeetingRecord(title:"Final before login",text:"Persisted final transcript")
        final.groupID = group.id;final = try fixture(library,final)
        var raw = MeetingRecord(title:"Audio without a transcript",text:"NEVER_UPLOAD_UNFINISHED",status:.failed,previewText:"NEVER_UPLOAD_LIVE")
        raw = try fixture(library,raw)
        var active = try library.save(MeetingRecord(title:"Active capture",text:"NEVER_UPLOAD_ACTIVE",status:.recording))
        let sync = LibrarySyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:adapter)
        try sync.connect(userId:user,server:server,transport:http,polling:false)
        check(sync.enabled,"login enables all-content sync without per-record selection")
        await sync.synchronize()
        var page = try await http.changes(cursor:nil)
        check(page.events.filter { $0.kind == .recording }.count == 2,"all stopped records enroll, including failed ASR/audio only")
        check(page.events.filter { $0.kind == .group }.count == 2,"empty groups enroll too")
        check(!String(decoding:try JSONEncoder().encode(page),as:UTF8.self).contains("NEVER_UPLOAD"),"live text must stay local")
        check(try library.load(active.id).userId == nil,"capture is not enrolled while active")
        var metadata = page.events.last { $0.id == raw.id }!.value!.recording!
        metadata.title = "Remote metadata update"
        try adapter.apply(LibrarySyncEntity(kind:.recording,id:raw.id,version:2,value:.recording(metadata)),userId:user)
        check(try library.load(raw.id).text == "NEVER_UPLOAD_UNFINISHED","metadata-only sync must preserve unfinished local text")
        let audio = LibraryAudioSyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:MacLibraryAudioAdapter(library:library))
        try audio.connect(userId:user,server:server,transport:audioHTTP);audio.setAutomaticEnabled(true)
        await audio.synchronizeAutomatically(recordingIds:[final.id,raw.id])
        check(audio.jobs.isEmpty && audio.lastFailure == nil,audio.message)
        for record in [final,raw] {
            let manifest = try await audioHTTP.manifest(record.id)
            check(manifest?.parts.count == 1,"automatic original uploaded")
            check(try manifest?.parts.first?.sha256 == LibraryAudioFiles.digest(library.audioURLs(for:record)[0]).0,"published original matches native bytes")
        }
        let receiver = try MeetingLibrary(root:root.appendingPathComponent("receiver"))
        let receiveSync = LibrarySyncEngine(root:receiver.root.appendingPathComponent("Sync"),adapter:MacLibrarySyncAdapter(library:receiver))
        try receiveSync.connect(userId:user,server:server,transport:http,polling:false);await receiveSync.synchronize()
        let down = LibraryAudioSyncEngine(root:receiver.root.appendingPathComponent("Sync"),adapter:MacLibraryAudioAdapter(library:receiver))
        try down.connect(userId:user,server:server,transport:audioHTTP);down.setAutomaticEnabled(true)
        await down.synchronizeAutomatically(recordingIds:[final.id,raw.id])
        check(down.jobs.isEmpty && down.lastFailure == nil,down.message)
        for source in [final,raw] {
            let record = try receiver.load(source.id)
            check(try Data(contentsOf:receiver.audioURLs(for:record)[0]) == Data(contentsOf:library.audioURLs(for:source)[0]),"automatic download preserves full original")
        }
        check(try receiver.load(raw.id).transcriptOrigin == .notGenerated,"audio-only record is not mislabeled a cloud transcript")
        let manifests = try await audioHTTP.manifest(final.id)
        await audio.synchronizeAutomatically(recordingIds:[final.id,raw.id]);check(audio.jobs.isEmpty,"repeated scan has no duplicate jobs")
        let unchanged = try await audioHTTP.manifest(final.id);check(manifests == unchanged,"repeated sync does not republish unchanged audio")
        sync.onEnabledChange = { audio.setAutomaticEnabled($0) }
        sync.pause();check(!sync.enabled && !audio.automaticEnabled,"one switch pauses text and original transfers")
        let paused = try library.save(MeetingRecord(title:"Created while paused",text:"Offline final"))
        sync.localDidChange();await sync.synchronize()
        check(try library.load(paused.id).userId == user,"paused records remain owned by the signed-in user")
        page = try await http.changes(cursor:nil);check(!page.events.contains { $0.id == paused.id },"paused content stays local")
        sync.disconnect();try sync.connect(userId:user,server:server,transport:http,polling:false)
        check(!sync.enabled,"explicit pause survives restart")
        sync.enable();await sync.synchronize()
        page = try await http.changes(cursor:nil);check(page.events.contains { $0.id == paused.id },"resume automatically includes new local records")
        active.status = .completed;active.text = "Final after capture";_ = try library.save(active)
        sync.localDidChange();await sync.synchronize()
        page = try await http.changes(cursor:nil);check(page.events.contains { $0.id == active.id && $0.value?.recording?.text == active.text },"new completed capture enrolls without selection")
        check(sync.pendingCount == 0 && sync.conflicts.isEmpty,sync.message)
        sync.disconnect();audio.disconnect()
        let (other,_,secondUser) = try await login("qa_other_"+UUID().uuidString.prefix(8))
        try sync.connect(userId:secondUser,server:server,transport:other,polling:false);await sync.synchronize()
        check(try library.list().isEmpty,"other account cannot see or claim previous account content")
        let otherPage = try await other.changes(cursor:nil);check(otherPage.events.isEmpty,"previous account content not uploaded to another user")
        sync.disconnect();try sync.connect(userId:user,server:server,transport:http,polling:false);await sync.synchronize()
        check(try library.list().count == 4,"original account restores all records")
        receiveSync.disconnect();sync.disconnect();down.disconnect()
        print("PASS: default whole-library text/groups and original uploads/downloads; audio-only items; live exclusion; incremental capture; repeat dedup; pause/restart/resume; account isolation")
    }
}
