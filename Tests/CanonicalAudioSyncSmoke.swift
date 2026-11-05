import Foundation
import AVFoundation

/// Real loopback HTTP + SQLite, synthetic account/audio; no user data or TCC.
@main struct CanonicalAudioSyncSmoke {
    @MainActor static func main() async throws {
        let server = URL(string:CommandLine.arguments[1])!, root = URL(fileURLWithPath:CommandLine.arguments[2])
        var request = URLRequest(url:server.appendingPathComponent("v1/auth/account")); request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["username":"qa_canonical_"+UUID().uuidString.prefix(8),"password":"synthetic-password"])
        let (data,response) = try await URLSession.shared.data(for:request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        let token = (try JSONSerialization.jsonObject(with:data) as! [String:Any])["token"] as! String
        let textHTTP = LibrarySyncHTTP(server:server,token:token), http = LibraryAudioHTTP(server:server,token:token)
        let user = try await textHTTP.identity().userId
        let library = try MeetingLibrary(root:root.appendingPathComponent("sender"))
        var groups = try library.organization(); let group = RecordingCollection(name:"Canonical group")
        groups.groups = [group]; try library.saveOrganization(groups)
        var record = try library.save(MeetingRecord(title:"Segmented continuation",text:"Final words",status:.recording))
        record.groupID = group.id
        var manifests:[URL] = [], originals:[URL:String] = [:]
        for (index,frames) in [24000,32000].enumerated() {
            let session = UUID(), capture = library.directory(for:record.id).appendingPathComponent("Capture/"+session.uuidString)
            let writer = try MacSegmentedTrackWriter(directory:capture.appendingPathComponent("microphone"),recordingID:session,streamID:"microphone",startFrame:0)
            try writer.append((0..<frames).map { Float(sin(Double($0)*0.07)*0.02) },startFrame:0)
            let manifest = try MacSegmentedManifest.finalize(recordingID:session,root:capture,trackManifests:[try writer.finish()])
            try BalancedAudioIO.save(CanonicalCaptureContext(mode:.continuous,meetingOffset:index == 0 ? 0 : 4),to:capture.appendingPathComponent("capture-context.json"))
            manifests.append(manifest)
            _ = try library.importAudio(manifest,into:&record,recordingDuration:Double(frames)/16000,captureSession:session,timelineEnd:index == 0 ? 1.5 : 6)
            let value = try CanonicalAudioReader(manifestURL:manifest).manifest!
            for stream in value.streams { for part in stream.segments {
                let url = capture.appendingPathComponent(stream.streamID+"/"+part.filename)
                originals[url] = try BalancedAudioIO.hashFile(url).1
            } }
            if index == 0 {
                let chapter = root.appendingPathComponent("chapter.json")
                try BalancedAudioIO.save(CanonicalAudioRange(sourceRecordingID:session,startFrame:0,endFrame:12000),to:chapter)
                _ = try library.importAudio(chapter,into:&record)
            }
            record.transcriptParagraphs.append(TranscriptParagraph(text:index == 0 ? "First words" : "Continued words",separator:index == 0 ? "" : "\n",start:index == 0 ? 0 : 4,end:index == 0 ? 1.5 : 6,audioFile:record.audioFiles.last,localStart:0))
        }
        record.text = record.paragraphText;record.status = .completed;record.pendingAudioFiles = [];record = try library.save(record)
        let paragraphIDs = record.transcriptParagraphs.map(\.id), archiveNames = record.audioFiles
        let sync = LibrarySyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:MacLibrarySyncAdapter(library:library))
        try sync.connect(userId:user,server:server,transport:textHTTP,polling:false); await sync.synchronize()
        precondition(sync.enabled && sync.pendingCount == 0 && sync.conflicts.isEmpty,sync.message)
        let adapter = MacLibraryAudioAdapter(library:library), lost = LostAudioReply(http)
        var audio = LibraryAudioSyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:adapter)
        try audio.connect(userId:user,server:server,transport:lost);audio.setAutomaticEnabled(true)
        await audio.synchronizeAutomatically(recordingIds:[record.id])
        precondition(audio.jobs.count == 1 && lost.lost,"lost upload reply must retain durable job")
        audio.disconnect()
        audio = LibraryAudioSyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:adapter)
        try audio.connect(userId:user,server:server,transport:http);audio.setAutomaticEnabled(true)
        await audio.synchronizeAutomatically(recordingIds:[record.id])
        precondition(audio.jobs.isEmpty && audio.lastFailure == nil,audio.message)
        let cloud = try await http.manifest(record.id)!
        precondition(cloud.parts.count == 2 && cloud.parts.map(\.durationMs) == [1500,2000] && cloud.parts.map(\.timelineStartMs) == [0,4000])
        precondition(cloud.parts.allSatisfy { $0.mimeType == "audio/mp4" })
        let sources = try await adapter.sources(record.id,userId:user)
        for (source,part) in zip(sources,cloud.parts) {
            let described = try LibraryAudioFiles.describe(source,recordingId:record.id)
            precondition(described == part && source.url.lastPathComponent != "final.manifest.json")
            let decoded = try AVAudioFile(forReading:source.url)
            precondition(decoded.length == Int64(part.durationMs)*16)
        }
        let local = try library.load(record.id)
        precondition(local.audioFiles == archiveNames && local.transcriptParagraphs.map(\.id) == paragraphIDs)
        await audio.synchronizeAutomatically(recordingIds:[record.id])
        let unchanged = try await http.manifest(record.id);precondition(unchanged == cloud,"unchanged sync must not republish")
        // Damage only a generated derivative. Retry regenerates it, preserving originals.
        try Data("damaged derived file".utf8).write(to:sources[0].url)
        let regenerated = try await adapter.sources(record.id,userId:user)
        let repaired = try AVAudioFile(forReading:regenerated[0].url);precondition(repaired.length == 24000)
        // A cache must not hide a damaged original. Restore synthetic bytes after checking.
        let original = originals.keys.first!, saved = try Data(contentsOf:original)
        try Data("damaged synthetic original".utf8).write(to:original)
        do { _ = try await adapter.sources(record.id,userId:user);preconditionFailure("corrupt original accepted") } catch {}
        try saved.write(to:original)
        for (url,hash) in originals { let current = try BalancedAudioIO.hashFile(url).1;precondition(current == hash) }
        // A second client consumes the same ordinary M4A protocol as iPhone.
        let receiver = try MeetingLibrary(root:root.appendingPathComponent("receiver"))
        let receiveText = LibrarySyncEngine(root:receiver.root.appendingPathComponent("Sync"),adapter:MacLibrarySyncAdapter(library:receiver))
        try receiveText.connect(userId:user,server:server,transport:textHTTP,polling:false);await receiveText.synchronize()
        let down = LibraryAudioSyncEngine(root:receiver.root.appendingPathComponent("Sync"),adapter:MacLibraryAudioAdapter(library:receiver))
        try down.connect(userId:user,server:server,transport:http);down.setAutomaticEnabled(true)
        await down.synchronizeAutomatically(recordingIds:[record.id])
        precondition(down.jobs.isEmpty && down.lastFailure == nil,down.message)
        let remote = try receiver.load(record.id), files = try receiver.audioURLs(for:remote)
        precondition(remote.groupID == group.id && remote.transcriptParagraphs.map(\.id) == paragraphIDs)
        precondition(remote.transcriptParagraphs.map(\.localStart) == [0,0])
        for (file,part) in zip(files,cloud.parts) { let digest = try LibraryAudioFiles.digest(file);precondition(digest.0 == part.sha256 && digest.1 == part.byteLength) }
        library.activeSyncUserId = UUID()
        do { _ = try await adapter.sources(record.id,userId:user);preconditionFailure("account switch exposed sources") } catch {}
        receiveText.disconnect();sync.disconnect();audio.disconnect();down.disconnect()
        print("PASS: segmented continuation -> verified full M4A -> automatic HTTP upload/restart -> second client download; timeline/group/paragraph IDs, original hashes, dedup, corrupt-cache repair, corrupt-original refusal and account isolation")
    }
}
